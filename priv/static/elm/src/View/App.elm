module View.App exposing (..)

import Browser
import Browser.Events
import Browser.Navigation as Nav
import Bitwise
import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Keyed as Keyed
import Html.Lazy as Lazy
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Ports exposing (..)
import Process
import Set exposing (Set)
import Task
import Time
import Types exposing (..)
import Url exposing (Url)
import View.Messages exposing (groupedMessageViews)
import View.Settings exposing (renderSettingsPage)
import View.Ui exposing (..)
import View.Auth as Auth
import View.Composer as Composer
import View.Home as Home
import View.Markdown as Markdown
import View.Notifications as Notifications


findMessage : Int -> List Message -> Maybe Message
findMessage msgId msgs =
    case msgs of
        [] ->
            Nothing

        m :: rest ->
            if m.id == msgId then
                Just m

            else
                findMessage msgId rest


-- VIEW


view : Model -> Browser.Document Msg
view model =
    { title = titleText model
    , body =
        [ if model.booting then
            div [ class "boot" ] [ text ("Loading " ++ model.appName ++ "...") ]

          else
            case model.me of
                Nothing ->
                    Auth.view model

                Just _ ->
                    renderApp model
        , renderToast model
        , renderCallLayer model
        ]
    }


titleText : Model -> String
titleText model =
    let
        unread =
            List.length (List.filter (\n -> not n.seen) model.notifs)
    in
    if unread > 0 then
        "(" ++ String.fromInt unread ++ ") " ++ model.appName

    else
        model.appName


renderToast : Model -> Html Msg
renderToast model =
    case model.toast of
        Just msg ->
            div [ class "toast toast-visible", attribute "role" "status", attribute "aria-live" "polite" ]
                [ span [ class "toast-text" ] [ text msg ]
                , button [ class "toast-close", attribute "aria-label" "Dismiss notification", onClick DismissToast ] [ callIcon "close" ]
                ]

        Nothing ->
            text ""


renderContextMenu : Model -> Html Msg
renderContextMenu model =
    case model.ctxMenu of
        Just menu ->
            div [ class "ctx-backdrop", onClick CloseCtx ]
                [ div
                    [ class "ctx-menu"
                    , attribute "role" "menu"
                    , attribute "aria-label" "Context menu"
                    , attribute "data-context-x" (String.fromInt menu.x)
                    , attribute "data-context-y" (String.fromInt menu.y)
                    , style "left" (String.fromInt menu.x ++ "px")
                    , style "top" (String.fromInt menu.y ++ "px")
                    ]
                    (List.indexedMap ctxItemView menu.items)
                ]

        Nothing ->
            text ""


renderModal : Model -> Html Msg
renderModal model =
    case model.modal of
        Just kind ->
            div [ class "modal", onClick CloseModal ]
                [ div [ class "modal-card action-modal", attribute "role" "dialog", attribute "aria-modal" "true", attribute "aria-label" "Conversation action", tabindex -1, stopClick ]
                    (modalContent kind model)
                ]

        Nothing ->
            text ""


modalContent : String -> Model -> List (Html Msg)
modalContent kind model =
    if kind == "server_profile" then
        case model.currentServerProfile of
            Nothing ->
                [ modalHead "Server profile" "Loading this member’s server identity…"
                , div [ class "modal-body server-profile-loading" ]
                    [ div [ class "loading-dot", attribute "aria-hidden" "true" ] []
                    , p [ class "muted" ] [ text "Loading profile…" ]
                    ]
                ]

            Just profile ->
                serverProfileModal model profile

    else if String.startsWith "reaction_picker:" kind then
        let
            messageId =
                String.toInt (String.dropLeft 16 kind) |> Maybe.withDefault 0
        in
        [ modalHead "React to message" "Choose a reaction. Selecting one toggles it for this message."
        , div [ class "modal-body" ]
            [ div [ class "emoji-picker-grid reaction-picker-grid", attribute "role" "listbox", attribute "aria-label" "Message reactions" ]
                (List.map (emojiReactionPickerButton messageId) emojiPickerItems)
            ]
        ]

    else if String.startsWith "pinned_messages:" kind then
        let
            canManage =
                model.currentServer
                    |> Maybe.map (\data -> serverHasPermission 4 data.server)
                    |> Maybe.withDefault False

            pinRow message =
                div [ class "pinned-message-row" ]
                    [ button
                        [ class "pinned-message-open"
                        , type_ "button"
                        , onClick (JumpToMessage message.id)
                        , attribute "aria-label" ("Jump to message from " ++ message.displayName)
                        ]
                        [ div [ class "pinned-message-meta" ]
                            [ b [] [ text message.displayName ]
                            , small [ class "muted" ] [ text (relativeTime model.serverTime message.createdAt) ]
                            ]
                        , div [ class "pinned-message-body" ] [ Markdown.preview message.body ]
                        ]
                    , if canManage then
                        button
                            [ class "btn secondary pinned-message-unpin"
                            , type_ "button"
                            , onClick (SetMessagePinned message False)
                            , title "Unpin message"
                            ]
                            [ text "Unpin" ]

                      else
                        text ""
                    ]
        in
        [ modalHead "Pinned messages" "Important messages saved for this channel."
        , div [ class "modal-body pinned-messages-modal" ]
            [ if List.isEmpty model.pinnedMessages then
                div [ class "empty compact-empty" ] [ text "No pinned messages in this channel." ]

              else
                div [ class "pinned-message-list" ] (List.map pinRow model.pinnedMessages)
            ]
        , div [ class "modal-actions" ] [ button [ class "btn secondary", type_ "button", onClick CloseModal ] [ text "Close" ] ]
        ]

    else if String.startsWith "delete_server:" kind then
        let
            serverId =
                String.toInt (String.dropLeft 14 kind) |> Maybe.withDefault 0

            confirmed =
                not (String.isEmpty model.modalTitle) && String.trim model.modalBody == model.modalTitle
        in
        [ modalHead "Delete server" "This permanently removes the server, its channels, messages, roles, Wires, and membership data."
        , div [ class "modal-body danger-confirm" ]
            [ p [] [ text "This cannot be undone. To confirm, type the server name exactly:" ]
            , div [ class "delete-server-name" ] [ text model.modalTitle ]
            , div [ class "field" ]
                [ label [ for "delete-server-confirm" ] [ text "Server name" ]
                , input
                    [ id "delete-server-confirm"
                    , value model.modalBody
                    , placeholder model.modalTitle
                    , onInput ModalBody
                    , attribute "autocomplete" "off"
                    , attribute "spellcheck" "false"
                    ]
                    []
                ]
            ]
        , div [ class "modal-actions" ]
            [ button [ class "btn secondary", onClick CloseModal ] [ text "Cancel" ]
            , button [ class "btn danger", disabled (not confirmed), onClick (ConfirmDeleteServer serverId) ] [ text "Delete server permanently" ]
            ]
        ]

    else if String.startsWith "new_thread" kind then
        [ modalHead "Create thread" "Start a longer conversation."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Category ID" ], input [ value model.modalUserIds, placeholder "Forum/category ID", onInput ModalUserIds ] [] ]
            , div [ class "field" ] [ label [] [ text "Title" ], input [ value model.modalTitle, placeholder "What is this about?", onInput ModalTitle ] [] ]
            , div [ class "field" ]
                [ label [] [ text "Body" ]
                , textarea [ id "compose", value model.modalBody, placeholder "Write the first post...", onInput ModalBody ] []
                , div [ class "composer-footer modal-composer-footer" ]
                    [ button [ class "btn secondary attach-btn", type_ "button", title "Attach files or images", onClick (BridgeEvent "pick_attachments" E.null) ] [ text "＋ Attach" ]
                    , small [ class "muted" ] [ text "Images, GIFs, and files up to 250 MB." ]
                    ]
                ]
            ]
        , modalActions "Create thread"
        ]

    else if kind == "new_forum" then
        [ modalHead "Create forum" "Make a public f/forum for focused discussions."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Forum name" ], input [ value model.modalTitle, placeholder "Gaming, News, Art...", onInput ModalTitle ] [] ]
            , div [ class "field" ] [ label [] [ text "f/ slug" ], input [ value model.modalUserIds, placeholder "gaming", onInput ModalUserIds ] [] ]
            , div [ class "field" ] [ label [] [ text "Description" ], textarea [ value model.modalBody, placeholder "What should people post here?", onInput ModalBody ] [] ]
            ]
        , modalActions "Create forum"
        ]

    else if kind == "new_dm" then
        [ modalHead "New message" "Choose one person for a DM, or a few for a group."
        , div [ class "modal-body people-modal-body" ]
            [ renderPeoplePicker Nothing model
            , div [ class "field" ] [ label [ attribute "for" "group-name" ] [ text "Group name · optional" ], input [ id "group-name", value model.modalTitle, maxlength 80, placeholder "Friday night, Study group…", onInput ModalTitle ] [] ]
            ]
        , modalActions "Start chat"
        ]

    else if String.startsWith "forward_message:" kind then
        let
            messageId =
                String.toInt (String.dropLeft 16 kind) |> Maybe.withDefault 0

            source =
                findMessage messageId model.msg

            query =
                String.toLower (String.trim model.modalBody)

            directTargets =
                model.convs
                    |> List.filter
                        (\conversation ->
                            conversation.requestState == "accepted"
                                && (String.isEmpty query || String.contains query (String.toLower (convName conversation)))
                        )
                    |> List.map
                        (\conversation ->
                            button
                                [ class "forward-target"
                                , type_ "button"
                                , onClick (ForwardMessage messageId "direct" conversation.id)
                                ]
                                [ convAvatar model conversation
                                , div [ class "grow" ]
                                    [ b [] [ text (convName conversation) ]
                                    , small [ class "muted" ] [ text "Direct message" ]
                                    ]
                                , span [ class "forward-target-arrow", attribute "aria-hidden" "true" ] [ text "→" ]
                                ]
                        )

            channelTargets =
                model.currentServer
                    |> Maybe.map
                        (\data ->
                            data.channels
                                |> List.filter
                                    (\channel ->
                                        channel.kind == "text"
                                            && (String.isEmpty query
                                                    || String.contains query (String.toLower channel.name)
                                                    || String.contains query (String.toLower data.server.name)
                                               )
                                    )
                                |> List.map
                                    (\channel ->
                                        button
                                            [ class "forward-target"
                                            , type_ "button"
                                            , onClick (ForwardMessage messageId "channel" channel.id)
                                            ]
                                            [ span [ class "forward-target-hash", attribute "aria-hidden" "true" ] [ text "#" ]
                                            , div [ class "grow" ]
                                                [ b [] [ text channel.name ]
                                                , small [ class "muted" ] [ text data.server.name ]
                                                ]
                                            , span [ class "forward-target-arrow", attribute "aria-hidden" "true" ] [ text "→" ]
                                            ]
                                    )
                        )
                    |> Maybe.withDefault []
        in
        [ modalHead "Forward message" "Choose where to send it. Plainwire keeps the original author attached."
        , div [ class "modal-body forward-modal" ]
            [ case source of
                Just message ->
                    div [ class "forward-preview" ]
                        [ span [ class "forward-preview-label" ] [ text ("From " ++ message.displayName) ]
                        , div [ class "forward-preview-body" ] [ Markdown.preview message.body ]
                        ]

                Nothing ->
                    div [ class "forward-preview" ] [ text "Message preview unavailable" ]
            , div [ class "field forward-search" ]
                [ label [ attribute "for" "forward-search" ] [ text "Find a destination" ]
                , input
                    [ id "forward-search"
                    , value model.modalBody
                    , placeholder "DM or channel name"
                    , onInput ModalBody
                    , attribute "autocomplete" "off"
                    , attribute "autofocus" "true"
                    ]
                    []
                ]
            , if not (String.isEmpty query) && List.isEmpty directTargets && List.isEmpty channelTargets then
                div [ class "forward-empty muted" ] [ text ("No destinations match “" ++ model.modalBody ++ "”.") ]

              else
                text ""
            , if List.isEmpty directTargets then
                text ""

              else
                div [ class "forward-section" ]
                    [ span [ class "eyebrow" ] [ text "Direct messages" ]
                    , div [ class "forward-targets" ] directTargets
                    ]
            , if List.isEmpty channelTargets then
                text ""

              else
                div [ class "forward-section" ]
                    [ span [ class "eyebrow" ] [ text "Current server" ]
                    , div [ class "forward-targets" ] channelTargets
                    ]
            ]
        , div [ class "modal-actions" ] [ button [ class "btn secondary", onClick CloseModal ] [ text "Cancel" ] ]
        ]

    else if kind == "keyboard_shortcuts" then
        [ modalHead "Keyboard shortcuts" "Fast navigation and call controls, without stealing keys while you type."
        , div [ class "modal-body shortcut-sheet" ]
            [ shortcutRow "Quick switcher" "Ctrl / Cmd + K"
            , shortcutRow "Open settings" "Ctrl / Cmd + ,"
            , shortcutRow "Emoji picker" "Ctrl / Cmd + E"
            , shortcutRow "GIF search" "Ctrl / Cmd + G"
            , shortcutRow "Edit your latest message (empty composer)" "↑"
            , shortcutRow "Search" "Ctrl / Cmd + F"
            , shortcutRow "Activity / mentions" "Ctrl / Cmd + I"
            , shortcutRow "Return to previous conversation / text channel" "Ctrl / Cmd + B"
            , shortcutRow "Create or join a server" "Ctrl / Cmd + Shift + N"
            , shortcutRow "Previous conversation or channel" "Alt + ↑"
            , shortcutRow "Next conversation or channel" "Alt + ↓"
            , shortcutRow "Previous unread DM" "Alt + Shift + ↑"
            , shortcutRow "Next unread DM" "Alt + Shift + ↓"
            , shortcutRow "Previous server" "Ctrl / Cmd + Alt + ←"
            , shortcutRow "Next server" "Ctrl / Cmd + Alt + →"
            , shortcutRow "Return to connected audio" "Ctrl / Cmd + Alt + A"
            , shortcutRow "Toggle mute while connected" "Ctrl / Cmd + Shift + M"
            , shortcutRow "Toggle deafen while connected" "Ctrl / Cmd + Shift + D"
            , shortcutRow "Toggle screen sharing" "Ctrl / Cmd + Shift + S"
            , shortcutRow "Expand / minimize active call" "Ctrl / Cmd + Shift + C"
            , shortcutRow "Answer incoming call" "Ctrl / Cmd + Enter"
            , shortcutRow "Start call in current DM" "Ctrl / Cmd + ["
            , shortcutRow "New group conversation" "Ctrl / Cmd + Shift + T"
            , shortcutRow "Upload files" "Ctrl / Cmd + Shift + U"
            , shortcutRow "Focus message box" "Ctrl / Cmd + Shift + L"
            , shortcutRow "Close current DM" "Ctrl / Cmd + Shift + Backspace"
            , shortcutRow "Show shortcuts / help" "Ctrl / Cmd + Shift + H"
            , shortcutRow "Show shortcuts" "Ctrl / Cmd + /"
            , shortcutRow "Close menus and dialogs" "Esc"
            , small [ class "muted shortcut-browser-note" ] [ text "Some browser-reserved shortcuts (especially Ctrl/Cmd + Shift + T) work most reliably in Plainwire Desktop." ]
            ]
        , div [ class "modal-actions" ] [ button [ class "btn", onClick CloseModal ] [ text "Done" ] ]
        ]

    else if kind == "emoji_picker" then
        [ modalHead "Emoji" "Pick one, or type a shortcode such as :eyes: directly in chat."
        , div [ class "modal-body emoji-picker" ]
            [ div [ class "emoji-picker-grid", attribute "role" "list" ]
                (List.map emojiPickerButton emojiPickerItems)
            , p [ class "muted emoji-picker-hint" ]
                [ text "Shortcodes render automatically in messages, including :eyes:, :thinking:, :fire:, :heart:, :skull:, and more." ]
            ]
        ]

    else if kind == "search" then
        [ modalHead "Find people" "Search for friends and threads."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Search" ], input [ value model.searchQuery, placeholder "Username or topic", onInput SearchQuery ] [] ]
            ]
        , modalActions "Search"
        ]

    else if String.startsWith "channel:" kind then
        let
            serverId =
                String.toInt (String.dropLeft 8 kind) |> Maybe.withDefault 0

            categories =
                model.serverCache
                    |> Dict.get serverId
                    |> Maybe.map .categories
                    |> Maybe.withDefault
                        (model.currentServer
                            |> Maybe.andThen
                                (\data ->
                                    if data.server.id == serverId then
                                        Just data.categories

                                    else
                                        Nothing
                                )
                            |> Maybe.withDefault []
                        )

            selectedCategory =
                String.toInt (String.trim model.modalUserIds)
        in
        [ modalHead "Create channel" "Add a text or voice room."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Channel name" ], input [ value model.modalTitle, maxlength 40, placeholder "general, updates, voice-chat", onInput ModalTitle ] [] ]
            , div [ class "field" ]
                [ label [] [ text "Type" ]
                , div [ class "choice-grid two" ]
                    [ choiceCard (model.modalBody == "text") "T" "Text channel" "Messages, files, and media." (SetModalChoice "body" "text")
                    , choiceCard (model.modalBody == "voice") "V" "Voice channel" "Drop-in audio and screen sharing." (SetModalChoice "body" "voice")
                    ]
                ]
            , if List.isEmpty categories then
                text ""

              else
                div [ class "field" ]
                    [ label [] [ text "Category" ]
                    , div [ class "segmented-choice" ]
                        (choicePill (selectedCategory == Nothing) "No category" (SetModalChoice "user_ids" "")
                            :: List.map
                                (\category -> choicePill (selectedCategory == Just category.id) category.name (SetModalChoice "user_ids" (String.fromInt category.id)))
                                categories
                        )
                    ]
            ]
        , modalActions "Create channel"
        ]

    else if kind == "join_invite" then
        [ modalHead "Join a Server" "Enter a Wire code or link to join."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Wire code" ], input [ value model.modalUserIds, placeholder "Paste a Wire link or code", onInput ModalUserIds ] [] ]
            ]
        , modalActions "Join"
        ]

    else if String.startsWith "invite:" kind then
        let
            serverId =
                String.toInt (String.dropLeft 7 kind) |> Maybe.withDefault 0

            channels =
                model.serverCache
                    |> Dict.get serverId
                    |> Maybe.map .channels
                    |> Maybe.withDefault
                        (model.currentServer
                            |> Maybe.andThen
                                (\data ->
                                    if data.server.id == serverId then
                                        Just data.channels

                                    else
                                        Nothing
                                )
                            |> Maybe.withDefault []
                        )

            selectedChannel =
                String.toInt (String.trim model.modalUserIds)

            channelChoices =
                choiceCard (selectedChannel == Nothing) "S" "Server home" "Let friends choose where to begin." (SetModalChoice "user_ids" "")
                    :: List.map
                        (\channel ->
                            choiceCard
                                (selectedChannel == Just channel.id)
                                (if channel.kind == "voice" then
                                    "♪"

                                 else
                                    "#"
                                )
                                channel.name
                                (if channel.kind == "voice" then
                                    "Open this voice room"

                                 else
                                    "Open this text channel"
                                )
                                (SetModalChoice "user_ids" (String.fromInt channel.id))
                        )
                        channels
        in
        [ modalHead "Create a Wire" "Choose where the Wire opens, then copy one secure link."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Open Wire in" ], div [ class "choice-grid invite-destination-grid" ] channelChoices ]
            , div [ class "field" ]
                [ label [] [ text "Usage limit" ]
                , div [ class "segmented-choice" ]
                    [ choicePill (model.modalBody == "0") "Unlimited" (SetModalChoice "body" "0")
                    , choicePill (model.modalBody == "1") "One use" (SetModalChoice "body" "1")
                    , choicePill (model.modalBody == "10") "10 uses" (SetModalChoice "body" "10")
                    , choicePill (model.modalBody == "25") "25 uses" (SetModalChoice "body" "25")
                    ]
                ]
            , div [ class "field" ]
                [ label [] [ text "Expires after" ]
                , select [ value model.modalTitle, onInput ModalTitle, attribute "aria-label" "Wire expiration" ]
                    [ option [ value "3600" ] [ text "1 hour" ]
                    , option [ value "86400" ] [ text "24 hours" ]
                    , option [ value "604800" ] [ text "7 days" ]
                    , option [ value "0" ] [ text "Never" ]
                    ]
                ]
            , p [ class "muted modal-hint" ] [ text "Only people with this link can join. Revoke a link below to stop new joins." ]
            , div [ class "invite-manager", attribute "data-invite-server" (String.dropLeft 7 kind) ] []
            ]
        , modalActions "Create Wire"
        ]

    else if String.startsWith "edit_server:" kind then
        let
            serverId =
                String.toInt (String.dropLeft 12 kind) |> Maybe.withDefault 0

            canDeleteServer =
                List.any (\server -> server.id == serverId && server.role == "owner") model.servers

            accentPresets =
                [ ( "Plainwire", "#5865f2" )
                , ( "Ocean", "#3b82f6" )
                , ( "Lagoon", "#14b8a6" )
                , ( "Forest", "#22c55e" )
                , ( "Sunset", "#f97316" )
                , ( "Rose", "#ec4899" )
                , ( "Violet", "#8b5cf6" )
                , ( "Graphite", "#64748b" )
                ]
        in
        [ modalHead "Customize server" "Give this server its own identity across desktop and mobile."
        , div [ class "modal-body server-customization" ]
            [ div [ class "server-customization-layout" ]
                [ aside [ class "server-customization-preview-column" ]
                    [ renderServerIdentityPreview model
                    , div [ class "server-preview-note" ]
                        [ b [] [ text "Live preview" ]
                        , p [ class "muted" ] [ text "Your banner, icon, name, description, and accent update here as you type." ]
                        ]
                    ]
                , div [ class "server-customization-fields" ]
                    [ section [ class "server-customization-section" ]
                        [ div [ class "server-customization-section-head" ] [ h3 [] [ text "Identity" ], p [ class "muted" ] [ text "The essentials people see in navigation and invites." ] ]
                        , div [ class "field" ]
                            [ label [] [ text "Server name" ]
                            , input [ value model.modalTitle, maxlength 80, placeholder "Server name", onInput ModalTitle ] []
                            , small [ class "muted field-counter" ] [ text (String.fromInt (String.length model.modalTitle) ++ " / 80") ]
                            ]
                        , div [ class "field" ]
                            [ label [] [ text "Description" ]
                            , textarea [ value model.modalBody, maxlength 280, rows 3, placeholder "What is this server for?", onInput ModalBody ] []
                            , small [ class "muted field-counter" ] [ text (String.fromInt (String.length model.modalBody) ++ " / 280") ]
                            ]
                        ]
                    , section [ class "server-customization-section" ]
                        [ div [ class "server-customization-section-head" ] [ h3 [] [ text "Artwork" ], p [ class "muted" ] [ text "Upload images or use an HTTPS image URL." ] ]
                        , div [ class "server-media-fields" ]
                            [ div [ class "field" ]
                                [ label [] [ text "Server icon" ]
                                , input [ value model.modalUserIds, placeholder "Image URL", onInput ModalUserIds, attribute "inputmode" "url" ] []
                                , div [ class "file-picker-row" ]
                                    [ input [ id "serverIconFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "serverIconFile")) ] []
                                    , label [ class "btn secondary file-picker-button", attribute "for" "serverIconFile" ] [ text "Upload icon" ]
                                    , button [ class "btn ghost", type_ "button", onClick (ModalUserIds ""), disabled (String.isEmpty model.modalUserIds) ] [ text "Remove" ]
                                    ]
                                , small [ class "muted" ] [ text "Square images work best." ]
                                ]
                            , div [ class "field" ]
                                [ label [] [ text "Server banner" ]
                                , input [ value model.modalBannerUrl, placeholder "Image URL", onInput ModalBannerUrl, attribute "inputmode" "url" ] []
                                , div [ class "file-picker-row" ]
                                    [ input [ id "serverBannerFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "serverBannerFile")) ] []
                                    , label [ class "btn secondary file-picker-button", attribute "for" "serverBannerFile" ] [ text "Upload banner" ]
                                    , button [ class "btn ghost", type_ "button", onClick (ModalBannerUrl ""), disabled (String.isEmpty model.modalBannerUrl) ] [ text "Remove" ]
                                    ]
                                , small [ class "muted" ] [ text "Wide images around 3:1 work best." ]
                                ]
                            ]
                        ]
                    , section [ class "server-customization-section" ]
                        [ div [ class "server-customization-section-head" ] [ h3 [] [ text "Accent theme" ], p [ class "muted" ] [ text "Used on the server home, channel details, and Wire cards." ] ]
                        , div [ class "server-theme-presets", attribute "aria-label" "Server accent themes" ]
                            (List.map
                                (\( name, color ) ->
                                    button
                                        [ type_ "button"
                                        , class ("server-theme-preset" ++ (if model.modalAccentColor == color then " active" else ""))
                                        , style "--server-accent" color
                                        , onClick (SetModalChoice "accent" color)
                                        , attribute "aria-label" ("Use " ++ name ++ " accent")
                                        , attribute "aria-pressed" (if model.modalAccentColor == color then "true" else "false")
                                        ]
                                        [ span [ class "server-theme-dot", style "background-color" color ] []
                                        , span [] [ text name ]
                                        ]
                                )
                                accentPresets
                            )
                        , div [ class "field server-color-field" ]
                            [ label [] [ text "Custom color" ]
                            , div [ class "server-color-control" ]
                                [ input [ type_ "color", value model.modalAccentColor, onInput ModalAccentColor, attribute "aria-label" "Server accent color" ] []
                                , input [ value model.modalAccentColor, placeholder "#5865f2", maxlength 7, onInput ModalAccentColor, attribute "aria-label" "Server accent hex value" ] []
                                , button [ class "btn ghost", type_ "button", onClick (SetModalChoice "accent" "#5865f2") ] [ text "Reset" ]
                                ]
                            ]
                        ]
                    , section [ class "server-customization-section" ]
                        [ div [ class "server-customization-section-head" ] [ h3 [] [ text "Welcome" ], p [ class "muted" ] [ text "Give new members context, links, or a few lightweight rules." ] ]
                        , div [ class "field" ]
                            [ label [] [ text "Welcome message" ]
                            , textarea [ value model.modalWelcome, maxlength 2000, rows 5, placeholder "A welcome note, a few rules, or where to start. Markdown is supported.", onInput (SetModalChoice "welcome") ] []
                            , small [ class "muted field-counter" ] [ text (String.fromInt (String.length model.modalWelcome) ++ " / 2,000 · Markdown supported") ]
                            ]
                        , if String.isEmpty (String.trim model.modalWelcome) then
                            text ""

                          else
                            div [ class "server-customize-preview", style "--server-accent" model.modalAccentColor ]
                                [ span [ class "eyebrow" ] [ text "Welcome preview" ]
                                , Html.node "pw-markdown" [ attribute "source" model.modalWelcome, attribute "no-embeds" "" ] []
                                ]
                        ]
                    ]
                ]
            , if canDeleteServer then
                div [ class "server-danger-zone" ]
                    [ div [ class "setting-copy" ]
                        [ b [] [ text "Delete server" ]
                        , small [ class "muted" ] [ text "Permanently remove this server and all server-owned data." ]
                        ]
                    , button
                        [ class "btn danger"
                        , type_ "button"
                        , onClick
                            (case List.filter (\server -> server.id == serverId) model.servers |> List.head of
                                Just server ->
                                    OpenDeleteServer server

                                Nothing ->
                                    NoOp
                            )
                        ]
                        [ text "Delete server…" ]
                    ]

              else
                text ""
            ]
        , modalActions "Save server"
        ]

    else if String.startsWith "create_category:" kind then
        [ modalHead "Create category" "Group related channels in the server sidebar."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Category name" ], input [ value model.modalTitle, maxlength 40, placeholder "Games, Projects, Social…", onInput ModalTitle ] [] ]
            , div [ class "category-preview" ]
                [ span [] [ text "▾" ]
                , b []
                    [ text
                        (if String.isEmpty (String.trim model.modalTitle) then
                            "NEW CATEGORY"

                         else
                            String.toUpper (String.trim model.modalTitle)
                        )
                    ]
                , span [ class "muted" ] [ text "# channel" ]
                ]
            ]
        , modalActions "Create category"
        ]

    else if String.startsWith "edit_category:" kind then
        let
            ids =
                String.split ":" (String.dropLeft 14 kind)

            serverId =
                listAt 0 ids |> Maybe.andThen String.toInt |> Maybe.withDefault 0

            categoryId =
                listAt 1 ids |> Maybe.andThen String.toInt |> Maybe.withDefault 0
        in
        [ modalHead "Edit category" "Rename this group or delete it without deleting its channels."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Category name" ], input [ value model.modalTitle, maxlength 40, placeholder "Games, Projects, Social…", onInput ModalTitle ] [] ]
            ]
        , div [ class "modal-actions category-modal-actions" ]
            [ button [ class "btn danger", onClick (DeleteCategory serverId categoryId), disabled (serverId == 0 || categoryId == 0) ] [ text "Delete category" ]
            , span [ class "grow" ] []
            , button [ class "btn secondary", onClick CloseModal ] [ text "Cancel" ]
            , button [ class "btn", onClick SubmitModal ] [ text "Save category" ]
            ]
        ]

    else if String.startsWith "edit_conversation:" kind then
        [ modalHead "Rename group" "Use a name everyone will recognize."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Group name" ], input [ value model.modalTitle, maxlength 80, placeholder "Group name", onInput ModalTitle ] [] ] ]
        , modalActions "Save name"
        ]

    else if String.startsWith "add_people:" kind then
        [ modalHead "Add people" "Choose people to bring into the conversation."
        , div [ class "modal-body people-modal-body" ]
            [ renderPeoplePicker (String.toInt (String.dropLeft 11 kind)) model ]
        , modalActions "Add people"
        ]

    else if String.startsWith "invite_result:" kind then
        let
            rest =
                String.dropLeft 14 kind

            parts =
                String.split ":" rest

            url =
                String.join ":" (List.drop 1 parts)

            displayLink =
                url
        in
        if String.startsWith "error" rest then
            [ modalHead "Wire failed" "Could not create Wire."
            , div [ class "modal-actions" ] [ button [ class "btn", onClick CloseModal ] [ text "Close" ] ]
            ]

        else
            [ modalHead "Wire created" "Share this Wire with friends."
            , div [ class "modal-body" ]
                [ div [ class "field" ]
                    [ label [] [ text "Wire link" ]
                    , div [ class "invite-code-box" ]
                        [ input [ class "invite-code-input", readonly True, value displayLink ] []
                        , button [ class "btn", onClick (CopyText displayLink) ] [ text "Copy" ]
                        ]
                    ]
                , p [ class "muted modal-hint" ] [ text "Anyone with this link can join the server." ]
                ]
            , div [ class "modal-actions" ]
                [ button [ class "btn", onClick CloseModal ] [ text "Done" ]
                ]
            ]

    else
        []


serverProfileModal : Model -> ServerProfile -> List (Html Msg)
serverProfileModal model profile =
    let
        member =
            profile.member

        user =
            member.user

        displayName =
            if String.isEmpty (String.trim member.nickname) then
                user.displayName

            else
                member.nickname

        avatarUrl =
            if String.isEmpty (String.trim member.serverAvatarUrl) then
                user.avatarUrl

            else
                member.serverAvatarUrl

        about =
            if String.isEmpty (String.trim member.serverBio) then
                "No server bio set."

            else
                member.serverBio

        viewingSelf =
            Maybe.map .id model.me == Just user.id

        roleChip role =
            span
                [ class "server-profile-role"
                , style "--role-color" (if String.isEmpty role.color then "var(--muted)" else role.color)
                ]
                [ span [ class "server-profile-role-dot", attribute "aria-hidden" "true" ] []
                , text role.name
                ]

        legacyRole =
            if member.role == "owner" then
                [ span [ class "server-profile-role legacy" ] [ text "Server owner" ] ]

            else if member.role == "admin" then
                [ span [ class "server-profile-role legacy" ] [ text "Administrator" ] ]

            else
                []
    in
    [ modalHead "Server profile" profile.serverName
    , div [ class "modal-body server-profile-modal" ]
        [ div [ class "server-profile-identity" ]
            [ presenceAvatar model.userStatuses user.id avatarUrl displayName "big"
            , div [ class "server-profile-copy" ]
                [ div [ class "profile-name-line" ]
                    [ h2 [ style "color" (if String.isEmpty member.roleColor then "var(--text1)" else member.roleColor) ] [ text displayName ]
                    , botBadge user.isBot
                    ]
                , p [ class "muted" ] [ text ("@" ++ user.username ++ " · " ++ profile.serverName) ]
                ]
            ]
        , div [ class "profile-bio server-profile-about" ]
            [ span [ class "profile-section-label" ] [ text "About on this server" ]
            , p [] [ text about ]
            ]
        , div [ class "server-profile-roles" ]
            [ span [ class "profile-section-label" ] [ text "Roles" ]
            , div [ class "server-profile-role-list" ]
                (legacyRole
                    ++ (if List.isEmpty profile.roles && List.isEmpty legacyRole then
                            [ span [ class "muted" ] [ text "No custom roles" ] ]

                        else
                            List.map roleChip profile.roles
                       )
                )
            ]
        , div [ class "profile-actions server-profile-actions" ]
            [ button [ class "btn secondary", onClick (Go ("#profile/" ++ String.fromInt user.id)) ] [ text "View full profile" ]
            , if profile.canManageRoles then
                button
                    [ class "btn secondary"
                    , onClick
                        (BridgeEvent "server_profile_edit_roles"
                            (E.object
                                [ ( "server_id", E.int profile.serverId )
                                , ( "user_id", E.int user.id )
                                ]
                            )
                        )
                    ]
                    [ text "Edit roles" ]

              else
                text ""
            , if viewingSelf then
                text ""

              else
                button [ class "btn", onClick (BridgeEvent "dm_user" (E.int user.id)) ] [ text "Message" ]
            , if viewingSelf then
                text ""

              else
                button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int user.id)) ] [ text "Call" ]
            , if profile.canBanMembers && not viewingSelf then
                button
                    [ class "btn danger"
                    , onClick
                        (BridgeEvent "server_profile_ban"
                            (E.object
                                [ ( "server_id", E.int profile.serverId )
                                , ( "user_id", E.int user.id )
                                , ( "display_name", E.string displayName )
                                ]
                            )
                        )
                    ]
                    [ text "Ban" ]

              else
                text ""
            ]
        ]
    ]


shortcutRow : String -> String -> Html Msg
shortcutRow labelText keys =
    div [ class "shortcut-row" ]
        [ span [] [ text labelText ]
        , kbd [ class "shortcut-key" ] [ text keys ]
        ]


emojiPickerItems : List ( String, String, String )
emojiPickerItems =
    [ ( "👀", ":eyes:", "Eyes" )
    , ( "😄", ":smile:", "Smile" )
    , ( "😂", ":joy:", "Joy" )
    , ( "🤣", ":rofl:", "Rolling on the floor laughing" )
    , ( "😉", ":wink:", "Wink" )
    , ( "😍", ":heart_eyes:", "Heart eyes" )
    , ( "🤔", ":thinking:", "Thinking" )
    , ( "😅", ":sweat_smile:", "Sweat smile" )
    , ( "😭", ":sob:", "Sobbing" )
    , ( "🥺", ":pleading_face:", "Pleading" )
    , ( "🫠", ":melting_face:", "Melting" )
    , ( "😎", ":sunglasses:", "Sunglasses" )
    , ( "💀", ":skull:", "Skull" )
    , ( "🔥", ":fire:", "Fire" )
    , ( "✨", ":sparkles:", "Sparkles" )
    , ( "🎉", ":tada:", "Party" )
    , ( "❤️", ":heart:", "Heart" )
    , ( "💙", ":blue_heart:", "Blue heart" )
    , ( "👍", ":thumbsup:", "Thumbs up" )
    , ( "👎", ":thumbsdown:", "Thumbs down" )
    , ( "👏", ":clap:", "Clap" )
    , ( "🙏", ":pray:", "Pray" )
    , ( "👋", ":wave:", "Wave" )
    , ( "🙌", ":raised_hands:", "Raised hands" )
    , ( "✅", ":check:", "Check" )
    , ( "❌", ":x:", "X" )
    , ( "⚠️", ":warning:", "Warning" )
    , ( "🚀", ":rocket:", "Rocket" )
    , ( "🐛", ":bug:", "Bug" )
    , ( "📌", ":pin:", "Pin" )
    ]


emojiPickerButton : ( String, String, String ) -> Html Msg
emojiPickerButton ( glyph, shortcode, labelText ) =
    button
        [ class "emoji-picker-item"
        , type_ "button"
        , title (labelText ++ " · " ++ shortcode)
        , attribute "aria-label" (labelText ++ " " ++ shortcode)
        , onClick (InsertComposerText glyph)
        ]
        [ span [ class "emoji-picker-glyph", attribute "aria-hidden" "true" ] [ text glyph ]
        , span [ class "emoji-picker-code" ] [ text shortcode ]
        ]


emojiReactionPickerButton : Int -> ( String, String, String ) -> Html Msg
emojiReactionPickerButton messageId ( glyph, shortcode, labelText ) =
    button
        [ class "emoji-picker-item"
        , type_ "button"
        , title (labelText ++ " · " ++ shortcode)
        , attribute "aria-label" ("React with " ++ labelText)
        , onClick (ToggleReaction messageId glyph)
        ]
        [ span [ class "emoji-picker-glyph", attribute "aria-hidden" "true" ] [ text glyph ]
        , span [ class "emoji-picker-code" ] [ text shortcode ]
        ]


navigateRelative : Int -> Model -> ( Model, Cmd Msg )
navigateRelative delta model =
    let
        dmRoutes =
            List.map (\conversation -> "#dm/" ++ String.fromInt conversation.id) model.convs

        channelRoutes =
            model.currentServer
                |> Maybe.map (.channels >> List.filter (\channel -> channel.kind == "text") >> List.map (\channel -> "#channel/" ++ String.fromInt channel.id))
                |> Maybe.withDefault []

        routes =
            dmRoutes ++ channelRoutes

        current =
            case model.active of
                DmView id ->
                    "#dm/" ++ String.fromInt id

                ChannelView id ->
                    "#channel/" ++ String.fromInt id

                _ ->
                    ""

        currentIndex =
            routes
                |> List.indexedMap Tuple.pair
                |> List.filter (\( _, route ) -> route == current)
                |> List.head
                |> Maybe.map Tuple.first
                |> Maybe.withDefault -1

        count =
            List.length routes

        nextIndex =
            if count == 0 then
                -1

            else if currentIndex < 0 then
                0

            else
                modBy count (currentIndex + delta)
    in
    if nextIndex < 0 then
        ( model, Cmd.none )

    else
        case listAt nextIndex routes of
            Just route ->
                ( model, setHash route )

            Nothing ->
                ( model, Cmd.none )


navigateUnread : Int -> Model -> ( Model, Cmd Msg )
navigateUnread delta model =
    let
        routes =
            model.convs
                |> List.filter (\conversation -> conversation.unread > 0)
                |> List.map (\conversation -> "#dm/" ++ String.fromInt conversation.id)

        current =
            case model.active of
                DmView id ->
                    "#dm/" ++ String.fromInt id

                _ ->
                    ""

        currentIndex =
            routes
                |> List.indexedMap Tuple.pair
                |> List.filter (\( _, route ) -> route == current)
                |> List.head
                |> Maybe.map Tuple.first
                |> Maybe.withDefault (if delta < 0 then 0 else -1)

        count =
            List.length routes
    in
    if count == 0 then
        ( { model | toast = Just "No unread direct messages." }, Cmd.none )

    else
        case listAt (modBy count (currentIndex + delta)) routes of
            Just route ->
                ( model, setHash route )

            Nothing ->
                ( model, Cmd.none )


navigateServer : Int -> Model -> ( Model, Cmd Msg )
navigateServer delta model =
    let
        ids =
            List.map .id model.servers

        currentId =
            model.currentServer |> Maybe.map (.server >> .id)

        currentIndex =
            ids
                |> List.indexedMap Tuple.pair
                |> List.filter (\( _, serverId ) -> Just serverId == currentId)
                |> List.head
                |> Maybe.map Tuple.first
                |> Maybe.withDefault -1

        count =
            List.length ids

        nextIndex =
            if count == 0 then
                -1

            else if currentIndex < 0 then
                if delta < 0 then
                    count - 1

                else
                    0

            else
                modBy count (currentIndex + delta)
    in
    case listAt nextIndex ids of
        Just serverId ->
            ( model, setHash ("#server/" ++ String.fromInt serverId) )

        Nothing ->
            ( model, Cmd.none )


modalHead : String -> String -> Html Msg
modalHead title subtitle =
    div [ class "modal-head" ]
        [ div [] [ h2 [] [ text title ], p [ class "muted" ] [ text subtitle ] ]
        , button [ class "btn ghost", attribute "aria-label" "Close dialog", type_ "button", onClick CloseModal ] [ text "×" ]
        ]


modalActions : String -> Html Msg
modalActions submitLabel =
    div [ class "modal-actions" ]
        [ button [ class "btn secondary", onClick CloseModal ] [ text "Cancel" ]
        , button [ class "btn", onClick SubmitModal ] [ text submitLabel ]
        ]


choiceCard : Bool -> String -> String -> String -> Msg -> Html Msg
choiceCard selected icon heading copy msg =
    button
        [ type_ "button"
        , class
            ("choice-card"
                ++ (if selected then
                        " selected"

                    else
                        ""
                   )
            )
        , onClick msg
        , attribute "aria-pressed"
            (if selected then
                "true"

             else
                "false"
            )
        ]
        [ span [ class "choice-card-icon" ] [ text icon ]
        , span [ class "choice-card-copy" ]
            [ b [] [ text heading ]
            , small [ class "muted" ] [ text copy ]
            ]
        , span [ class "choice-card-check", attribute "aria-hidden" "true" ] []
        ]


choicePill : Bool -> String -> Msg -> Html Msg
choicePill selected label msg =
    button
        [ type_ "button"
        , class
            ("choice-pill"
                ++ (if selected then
                        " selected"

                    else
                        ""
                   )
            )
        , onClick msg
        , attribute "aria-pressed"
            (if selected then
                "true"

             else
                "false"
            )
        ]
        [ text label ]


ctxItemView : Int -> CtxItem -> Html Msg
ctxItemView idx item =
    button
        [ type_ "button"
        , class
            ("ctx-item"
                ++ (if item.danger then
                        " ctx-danger"

                    else
                        ""
                   )
                ++ (if item.sep then
                        " ctx-sep-before"

                    else
                        ""
                   )
            )
        , attribute "role" "menuitem"
        , onClick (CtxAction idx)
        ]
        [ span [ class "ctx-icon", attribute "aria-hidden" "true" ] [ text (Maybe.withDefault "" item.icon) ]
        , span [] [ text item.label ]
        ]


messageContext : Model -> Message -> Int -> Int -> ContextMenu
messageContext model message x y =
    let
        mine =
            Maybe.map .id model.me == Just message.userId

        base =
            [ { label = "Reply", icon = Just "↩", danger = False, sep = False, msg = SetReplyTo message }
            , { label = "Forward", icon = Just "➜", danger = False, sep = False, msg = OpenForwardModal message }
            , { label = "Copy text", icon = Just "⧉", danger = False, sep = False, msg = CopyText message.body }
            ]

        reactionItems =
            if message.id <= 0 then
                []

            else
                [ { label = "React 👍", icon = Just "👍", danger = False, sep = True, msg = ToggleReaction message.id "👍" }
                , { label = "React ❤️", icon = Just "❤️", danger = False, sep = False, msg = ToggleReaction message.id "❤️" }
                , { label = "React 😂", icon = Just "😂", danger = False, sep = False, msg = ToggleReaction message.id "😂" }
                , { label = "React 🔥", icon = Just "🔥", danger = False, sep = False, msg = ToggleReaction message.id "🔥" }
                , { label = "More reactions…", icon = Just "+", danger = False, sep = False, msg = OpenReactionPicker message.id }
                ]

        pinItems =
            case ( message.scope, model.currentServer ) of
                ( "channel", Just data ) ->
                    if message.id > 0 && serverHasPermission 4 data.server then
                        [ { label = if message.pinned then "Unpin message" else "Pin message"
                          , icon = Just "📌"
                          , danger = False
                          , sep = True
                          , msg = SetMessagePinned message (not message.pinned)
                          }
                        ]

                    else
                        []

                _ ->
                    []

        authorItems =
            if mine then
                []

            else
                case ( message.scope, model.currentServer ) of
                    ( "channel", Just data ) ->
                        [ { label = "View server profile", icon = Just "◉", danger = False, sep = True, msg = ShowServerProfile data.server.id message.userId }
                        , { label = "View full profile", icon = Just "○", danger = False, sep = False, msg = Go ("#profile/" ++ String.fromInt message.userId) }
                        , { label = "Copy author username", icon = Just "@", danger = False, sep = False, msg = CopyText ("@" ++ message.username) }
                        ]

                    _ ->
                        [ { label = "View author profile", icon = Just "○", danger = False, sep = True, msg = Go ("#profile/" ++ String.fromInt message.userId) }
                        , { label = "Copy author username", icon = Just "@", danger = False, sep = False, msg = CopyText ("@" ++ message.username) }
                        ]

        mineItems =
            if mine then
                (if message.forwardedFrom == Nothing then
                    [ { label = "Edit message", icon = Just "✎", danger = False, sep = True, msg = StartEditMessage message }
                    , { label = "Delete message", icon = Just "×", danger = True, sep = False, msg = DeleteMessage message.id }
                    ]

                 else
                    [ { label = "Delete message", icon = Just "×", danger = True, sep = True, msg = DeleteMessage message.id } ]
                )

            else
                []
    in
    { items = base ++ reactionItems ++ pinItems ++ authorItems ++ mineItems, x = x, y = y }


conversationContext : Model -> Conversation -> Int -> Int -> ContextMenu
conversationContext _ c x y =
    let
        isGroup =
            c.memberCount > 2

        canManageMembers =
            isGroup && (c.groupRole == "owner" || c.groupRole == "moderator")

        canRename =
            isGroup && c.groupRole == "owner"

        groupItems =
            (if canRename then
                [ { label = "Rename group", icon = Just "✎", danger = False, sep = False, msg = EditConversationModal c } ]

             else
                []
            )
                ++ (if canManageMembers then
                        [ { label = "Add people", icon = Just "+", danger = False, sep = False, msg = AddPeopleModal c.id } ]

                    else
                        []
                   )

        closeItem =
            if isGroup then
                { label = "Leave group", icon = Just "×", danger = True, sep = True, msg = LeaveConversation c.id }

            else
                { label = "Close", icon = Just "×", danger = False, sep = True, msg = CloseConversation c.id }
    in
    { items =
        [ { label = "Open", icon = Just "→", danger = False, sep = False, msg = Go ("#dm/" ++ String.fromInt c.id) }
        , { label = "Mark read", icon = Just "✓", danger = False, sep = False, msg = MarkConvRead c.id }
        ]
            ++ groupItems
            ++ [ closeItem ]
    , x = x
    , y = y
    }


serverAdministratorBit : Int
serverAdministratorBit =
    1073741824


serverHasPermission : Int -> Server -> Bool
serverHasPermission permission server =
    server.role == "owner"
        || server.role == "admin"
        || Bitwise.and server.permissions serverAdministratorBit /= 0
        || Bitwise.and server.permissions permission /= 0


serverContext : Server -> Int -> Int -> ContextMenu
serverContext server x y =
    let
        wireItems =
            if serverHasPermission 256 server then
                [ { label = "Create Wire", icon = Just "+", danger = False, sep = True, msg = InviteModal server.id } ]

            else
                []

        management =
            if serverHasPermission 16 server then
                [ { label = "Edit server", icon = Just "✎", danger = False, sep = List.isEmpty wireItems, msg = EditServerModal server } ]

            else
                []

        deletion =
            if server.role == "owner" then
                [ { label = "Delete server", icon = Just "×", danger = True, sep = True, msg = OpenDeleteServer server } ]

            else
                []
    in
    { items =
        [ { label = "Open server", icon = Just "→", danger = False, sep = False, msg = Go ("#server/" ++ String.fromInt server.id) }
        , { label = "Copy server name", icon = Just "⧉", danger = False, sep = False, msg = CopyText server.name }
        ]
            ++ wireItems
            ++ management
            ++ deletion
            ++ [ { label = "Copy server ID", icon = Just "#", danger = False, sep = True, msg = CopyText (String.fromInt server.id) } ]
    , x = x
    , y = y
    }


serverMemberContext : Int -> ServerMember -> Int -> Int -> ContextMenu
serverMemberContext serverId member x y =
    { items =
        [ { label = "View server profile", icon = Just "◉", danger = False, sep = False, msg = ShowServerProfile serverId member.user.id }
        , { label = "View full profile", icon = Just "○", danger = False, sep = False, msg = Go ("#profile/" ++ String.fromInt member.user.id) }
        , { label = "Copy username", icon = Just "@", danger = False, sep = True, msg = CopyText ("@" ++ member.user.username) }
        , { label = "Copy user ID", icon = Just "#", danger = False, sep = False, msg = CopyText (String.fromInt member.user.id) }
        ]
    , x = x
    , y = y
    }


channelContext : Channel -> Int -> Int -> ContextMenu
channelContext channel x y =
    let
        target =
            if channel.kind == "voice" then
                "#voice/"

            else
                "#channel/"

        kindLabel =
            if channel.kind == "voice" then
                "voice channel"

            else
                "channel"
    in
    { items =
        [ { label = "Open " ++ kindLabel, icon = Just "→", danger = False, sep = False, msg = Go (target ++ String.fromInt channel.id) }
        , { label = "Copy channel name", icon = Just "#", danger = False, sep = False, msg = CopyText channel.name }
        , { label = "Copy channel ID", icon = Just "⧉", danger = False, sep = True, msg = CopyText (String.fromInt channel.id) }
        ]
    , x = x
    , y = y
    }


userContext : Model -> User -> Int -> Int -> ContextMenu
userContext model user x y =
    let
        isSelf =
            Maybe.map .id model.me == Just user.id

        relationship =
            List.filter (\friend -> friend.user.id == user.id) model.friends |> List.head

        blocked =
            Maybe.map .status relationship == Just "blocked"

        blockedByMe =
            Maybe.map .blockedByMe relationship == Just True

        actions =
            if isSelf then
                [ { label = "View my profile", icon = Just "○", danger = False, sep = False, msg = Go ("#profile/" ++ String.fromInt user.id) }
                , { label = "Copy username", icon = Just "⧉", danger = False, sep = False, msg = CopyText ("@" ++ user.username) }
                ]

            else
                [ { label = "View profile", icon = Just "○", danger = False, sep = False, msg = Go ("#profile/" ++ String.fromInt user.id) }
                , { label = "Message", icon = Just "✉", danger = False, sep = False, msg = BridgeEvent "dm_user" (E.int user.id) }
                , { label = "Copy username", icon = Just "⧉", danger = False, sep = False, msg = CopyText ("@" ++ user.username) }
                , if blocked && blockedByMe then
                    { label = "Unblock", icon = Just "✓", danger = False, sep = True, msg = BridgeEvent "unblock_user" (E.int user.id) }

                  else if blocked then
                    { label = "Unavailable", icon = Just "⊘", danger = False, sep = True, msg = NoOp }

                  else
                    { label = "Block", icon = Just "⊘", danger = True, sep = True, msg = BridgeEvent "block_user" (E.int user.id) }
                ]
    in
    { items = actions, x = x, y = y }


renderCallLayer : Model -> Html Msg
renderCallLayer model =
    let
        popups =
            List.filterMap identity
                [ Maybe.map (\i -> renderCallPopup "incoming" i model) model.callUI.incoming
                , Maybe.map (\o -> renderCallPopup "outgoing" o model) model.callUI.outgoing
                ]

        activeOverlay =
            case model.callUI.active of
                Just active ->
                    let
                        joinedCall =
                            isJoinedCall active.conversationId model
                    in
                    if not joinedCall || model.callMode == Ringing || model.callMode == Calling then
                        []

                    else if active.expanded then
                        [ renderExpandedCallOverlay active model ]

                    else
                        [ renderCompactCallBar active model ]

                _ ->
                    []
    in
    if List.isEmpty popups && List.isEmpty activeOverlay then
        text ""

    else
        div [ class "call-layer" ] (popups ++ activeOverlay)


callConversation : Int -> Model -> Maybe Conversation
callConversation conversationId model =
    model.convs
        |> List.filter (\conversation -> conversation.id == conversationId)
        |> List.head


callRoster : Model -> Conversation -> List MemberUser
callRoster model conversation =
    case Dict.get conversation.id model.conversationMembers of
        Just members ->
            if List.isEmpty members then
                conversation.members

            else
                members

        Nothing ->
            conversation.members


callJoinedUserIds : Model -> Int -> List Int
callJoinedUserIds model conversationId =
    let
        activeUsers =
            case model.callUI.active of
                Just active ->
                    if active.conversationId == conversationId then
                        List.map .userId active.users

                    else
                        []

                Nothing ->
                    []

        savedUsers =
            Dict.get conversationId model.activeCalls
                |> Maybe.map (\call -> List.map .userId call.users)
                |> Maybe.withDefault []
    in
    activeUsers ++ savedUsers


callPersonName : String -> String -> String
callPersonName displayName username =
    if String.isEmpty (String.trim displayName) then
        if String.isEmpty (String.trim username) then
            "Someone"

        else
            String.trim username

    else
        String.trim displayName


uniqueCallPeople : List { userId : Int, name : String, avatarUrl : String } -> List { userId : Int, name : String, avatarUrl : String }
uniqueCallPeople people =
    List.foldl
        (\person ( seen, kept ) ->
            if List.member person.userId seen then
                ( seen, kept )

            else
                ( person.userId :: seen, kept ++ [ person ] )
        )
        ( [], [] )
        people
        |> Tuple.second


uniqueIds : List Int -> List Int
uniqueIds ids =
    List.foldl
        (\id kept ->
            if List.member id kept then
                kept

            else
                kept ++ [ id ]
        )
        []
        ids


callEnglishList : List String -> String
callEnglishList names =
    case List.reverse names of
        [] ->
            ""

        [ only ] ->
            only

        last :: earlier ->
            String.join ", " (List.reverse earlier)
                ++ (if List.isEmpty (List.drop 1 earlier) then
                        " and "

                    else
                        ", and "
                   )
                ++ last


{-| People still being called. The ringing event's profile is the caller, so it is never used here. -}
pendingCallees : Model -> Int -> List { userId : Int, name : String, avatarUrl : String }
pendingCallees model conversationId =
    let
        myId =
            Maybe.map .id model.me

        joined =
            callJoinedUserIds model conversationId

        stillWaiting userId =
            myId /= Just userId && not (List.member userId joined)

        members =
            case callConversation conversationId model of
                Just conversation ->
                    callRoster model conversation

                Nothing ->
                    Dict.get conversationId model.conversationMembers |> Maybe.withDefault []

        fromMembers =
            members
                |> List.filterMap
                    (\member ->
                        if stillWaiting member.user.id then
                            Just
                                { userId = member.user.id
                                , name = callPersonName member.user.displayName member.user.username
                                , avatarUrl = member.user.avatarUrl
                                }

                        else
                            Nothing
                    )

        fromPeer =
            case callConversation conversationId model of
                Just conversation ->
                    if conversation.memberCount <= 2 && conversation.peerId > 0 && stillWaiting conversation.peerId && not (String.isEmpty (String.trim conversation.peerName)) then
                        [ { userId = conversation.peerId, name = String.trim conversation.peerName, avatarUrl = conversation.peerAvatarUrl } ]

                    else
                        []

                Nothing ->
                    []
    in
    (if List.isEmpty fromMembers then
        fromPeer

     else
        fromMembers
    )
        |> uniqueCallPeople
        |> List.sortBy (\person -> String.toLower person.name)


unnamedWaitingCount : Model -> Int -> List { userId : Int, name : String, avatarUrl : String } -> Int
unnamedWaitingCount model conversationId callees =
    if not (List.isEmpty callees) then
        0

    else
        case callConversation conversationId model of
            Nothing ->
                0

            Just conversation ->
                let
                    roster =
                        callRoster model conversation

                    othersInRoster =
                        List.filter (\member -> Maybe.map .id model.me /= Just member.user.id) roster

                    remoteJoined =
                        callJoinedUserIds model conversationId
                            |> List.filter (\userId -> Maybe.map .id model.me /= Just userId)
                            |> uniqueIds
                            |> List.length

                    countedOthers =
                        Basics.max 0 (conversation.memberCount - 1 - remoteJoined)
                in
                if not (List.isEmpty othersInRoster) || (conversation.memberCount <= 2 && conversation.peerId > 0) then
                    0

                else if not (List.isEmpty roster) && conversation.memberCount <= List.length roster then
                    0

                else
                    countedOthers


callWaitingStatus : Model -> Int -> String
callWaitingStatus model conversationId =
    let
        callees =
            pendingCallees model conversationId

        names =
            List.map .name callees

        fallback =
            unnamedWaitingCount model conversationId callees
    in
    case names of
        [ only ] ->
            "Waiting for " ++ only

        _ ->
            if List.length names >= 2 && List.length names <= 3 then
                "Waiting for " ++ callEnglishList names

            else if List.length names > 3 then
                "Waiting for " ++ String.fromInt (List.length names) ++ " people"

            else if fallback == 1 then
                "Waiting for 1 person"

            else if fallback > 1 then
                "Waiting for " ++ String.fromInt fallback ++ " people"

            else
                "Waiting for others"


outgoingCallParty : Model -> CallPopup -> { name : String, detail : String, avatarUrl : String }
outgoingCallParty model popup =
    let
        conversation =
            callConversation popup.conversationId model

        callees =
            pendingCallees model popup.conversationId

        names =
            List.map .name callees

        named =
            conversation |> Maybe.map (\item -> String.trim item.name) |> Maybe.withDefault ""

        name =
            if named /= "" then
                named

            else
                case names of
                    [] ->
                        "Voice call"

                    [ only ] ->
                        only

                    _ ->
                        if List.length names <= 3 then
                            callEnglishList names

                        else
                            "Group call"

        avatarUrl =
            case callees of
                [ one ] ->
                    one.avatarUrl

                _ ->
                    conversation |> Maybe.map .avatarUrl |> Maybe.withDefault ""
    in
    { name = name
    , detail = outgoingWaitingDetail names (unnamedWaitingCount model popup.conversationId callees)
    , avatarUrl = avatarUrl
    }


renderCallPopup : String -> CallPopup -> Model -> Html Msg
renderCallPopup kind popup model =
    let
        incoming =
            kind == "incoming"

        kicker =
            if incoming then
                "Incoming voice call"

            else
                "Outgoing voice call"

        party =
            if incoming then
                { name = popup.displayName
                , detail = "Answer to join the call. Your microphone stays off until you accept."
                , avatarUrl = popup.avatarUrl
                }

            else
                outgoingCallParty model popup

        avatarHtml =
            avatarImg party.avatarUrl party.name "big"

        actions =
            case kind of
                "incoming" ->
                    div [ class "call-popup-actions" ]
                        [ button [ class "btn call-decline", onClick (DeclineCall popup.conversationId) ] [ text "Decline" ]
                        , button [ class "btn call-accept", onClick (AcceptCall popup.conversationId) ] [ text "Accept" ]
                        ]

                "outgoing" ->
                    div [ class "call-popup-actions" ]
                        [ button [ class "btn call-decline", onClick (BridgeEvent "cancel_call" (E.int popup.conversationId)) ] [ text "Cancel" ]
                        ]

                _ ->
                    text ""
    in
    div
        [ class ("call-popup " ++ kind)
        , attribute "role" "dialog"
        , attribute "aria-label" (kicker ++ " with " ++ party.name)
        ]
        [ div [ class "call-popup-head", attribute "data-call-drag-handle" "true" ]
            [ div [ class "call-avatar-wrap" ]
                [ avatarHtml ]
            , div [ class "call-popup-copy" ]
                [ div [ class "call-popup-kicker" ]
                    [ callIcon "audio"
                    , span [] [ text kicker ]
                    ]
                , p [ class "call-popup-title" ] [ text party.name ]
                , p [ class "call-popup-sub" ] [ text party.detail ]
                ]
            ]
        , actions
        ]


outgoingWaitingDetail : List String -> Int -> String
outgoingWaitingDetail names fallbackCount =
    case names of
        [ only ] ->
            "Ringing… waiting for " ++ only ++ " to answer."

        _ ->
            if List.length names >= 2 && List.length names <= 3 then
                "Ringing… waiting for " ++ callEnglishList names ++ " to answer."

            else if List.length names > 3 then
                "Waiting for " ++ String.fromInt (List.length names) ++ " people"

            else if fallbackCount <= 0 then
                "Ringing…"

            else if fallbackCount == 1 then
                "Waiting for 1 person"

            else
                "Waiting for " ++ String.fromInt fallbackCount ++ " people"



liveCallTimer : String -> Int -> Html Msg
liveCallTimer className startTime =
    node "pw-call-timer"
        [ class className
        , attribute "data-call-start" (String.fromInt startTime)
        , attribute "role" "timer"
        ]
        []


renderCompactCallBar : ActiveCall -> Model -> Html Msg
renderCompactCallBar active model =
    let
        myId =
            Maybe.map .id model.me

        activeUsers =
            List.filter (\user -> not user.reconnecting) active.users

        remoteUsers =
            List.filter (\user -> Just user.userId /= myId) activeUsers

        count =
            List.length activeUsers

        reconnectingCount =
            List.length active.users - count

        reconnectingSuffix =
            if reconnectingCount > 0 then
                " · " ++ String.fromInt reconnectingCount ++ " reconnecting"

            else
                ""

        connectedCount =
            List.length (List.filter .connected remoteUsers)

        failedCount =
            List.length (List.filter .connectionFailed remoteUsers)

        countText =
            if List.isEmpty remoteUsers then
                callWaitingStatus model active.conversationId ++ reconnectingSuffix

            else if failedCount > 0 then
                "Audio failed · Open to retry" ++ reconnectingSuffix

            else if connectedCount == List.length remoteUsers then
                "Audio connected · "
                    ++ String.fromInt count
                    ++ " participant"
                    ++ (if count /= 1 then
                            "s"

                        else
                            ""
                       )
                    ++ reconnectingSuffix

            else
                "Connecting audio · " ++ String.fromInt connectedCount ++ "/" ++ String.fromInt (List.length remoteUsers) ++ reconnectingSuffix

        userAvatars =
            List.take 3 active.users
                |> List.map (\u -> avatarImg u.avatarUrl u.displayName "small")

        overflow =
            count - 3
    in
    div [ class "call-bar compact" ]
        [ div
            [ class "call-bar-drag-area"
            , attribute "data-call-drag-handle" "true"
            , attribute "role" "button"
            , attribute "tabindex" "0"
            , attribute "aria-label" "Open call details"
            , title "Drag to move · click for details"
            , onClick ToggleCallOverlay
            , preventDefaultOn "keydown"
                (D.field "key" D.string
                    |> D.andThen
                        (\key ->
                            if key == "Enter" || key == " " then
                                D.succeed ( ToggleCallOverlay, True )

                            else
                                D.fail "ignore"
                        )
                )
            ]
            [ div [ class "call-bar-icon" ] [ callIcon "audio" ]
            , div [ class "call-bar-info" ]
                [ span [ class "call-bar-title" ] [ text "Voice call" ]
                , span [ class "call-bar-sub" ] [ text countText ]
                ]
            , div [ class "call-bar-avatars" ]
                (userAvatars
                    ++ (if overflow > 0 then
                            [ div [ class "avatar small" ] [ text ("+" ++ String.fromInt overflow) ] ]

                        else
                            []
                       )
                )
            ]
        , div [ class "call-bar-controls", attribute "aria-label" "Call controls" ]
            [ button
                [ class
                    ("btn icon-btn"
                        ++ (if model.voice.muted then
                                " call-muted"

                            else
                                ""
                           )
                    )
                , title
                    (if model.voice.muted then
                        "Unmute"

                     else
                        "Mute"
                    )
                , attribute "aria-pressed"
                    (if model.voice.muted then
                        "true"

                     else
                        "false"
                    )
                , onClickStop (BridgeEvent "toggle_mute" E.null)
                ]
                [ callIcon
                    (if model.voice.muted then
                        "mic off"

                     else
                        "mic"
                    )
                ]
            , button
                [ class
                    ("btn icon-btn"
                        ++ (if model.voice.deafened then
                                " call-muted"

                            else
                                ""
                           )
                    )
                , title
                    (if model.voice.deafened then
                        "Undeafen"

                     else
                        "Deafen"
                    )
                , attribute "aria-pressed"
                    (if model.voice.deafened then
                        "true"

                     else
                        "false"
                    )
                , onClickStop (BridgeEvent "toggle_deafen" E.null)
                ]
                [ callIcon
                    (if model.voice.deafened then
                        "audio off"

                     else
                        "audio"
                    )
                ]
            , if model.voice.screenShare then
                button [ class "btn icon-btn share-active", title "Stop sharing", onClickStop StopScreenShare ]
                    [ callIcon "screen off" ]

              else
                button [ class "btn icon-btn", title "Share screen", onClickStop StartScreenShare ]
                    [ callIcon "screen" ]
            , button [ class "btn icon-btn call-decline", title "Leave call", onClickStop EndCall ]
                [ callIcon "hangup" ]
            ]
        ]


callIcon : String -> Html Msg
callIcon kind =
    span [ class ("call-icon call-icon-" ++ String.replace " " " call-icon-" kind), attribute "aria-hidden" "true" ] []


renderExpandedCallOverlay : ActiveCall -> Model -> Html Msg
renderExpandedCallOverlay active model =
    let
        remoteUsers =
            List.filter (\u -> Just u.userId /= Maybe.map .id model.me) active.users

        connected =
            not (List.isEmpty remoteUsers) && List.all .connected remoteUsers

        statusText =
            if List.any .connectionFailed remoteUsers then
                "Connection needs attention"

            else if connected then
                "Connected"

            else if List.isEmpty remoteUsers then
                callWaitingStatus model active.conversationId

            else
                "Connecting audio"

        control icon label activeState action =
            button
                [ class
                    ("call-control"
                        ++ (if activeState then
                                " active"

                            else
                                ""
                           )
                    )
                , onClick action
                , attribute "aria-pressed"
                    (if activeState then
                        "true"

                     else
                        "false"
                    )
                ]
                [ callIcon icon, span [] [ text label ] ]

        facepileUsers =
            List.take 4 active.users

        facepileOverflow =
            Basics.max 0 (List.length active.users - List.length facepileUsers)
    in
    div [ class "call-overlay expanded" ]
        [ div [ class "call-overlay-header", attribute "data-call-drag-handle" "true" ]
            [ div [ class "call-overlay-heading" ]
                [ div [ class "call-overlay-title-row" ]
                    [ div [ class "call-overlay-title" ] [ text "In the room" ]
                    , div [ class "call-overlay-facepile", attribute "aria-label" "Call participants" ]
                        (List.map
                            (\u ->
                                button
                                    [ type_ "button"
                                    , class "call-overlay-face"
                                    , onClick (ShowUserPopup u.userId)
                                    , title ("Open " ++ u.displayName ++ "'s profile")
                                    ]
                                    [ avatarImg u.avatarUrl u.displayName "tiny" ]
                            )
                            facepileUsers
                            ++ (if facepileOverflow > 0 then
                                    [ span [ class "call-overlay-face-overflow", title (String.fromInt facepileOverflow ++ " more participants") ] [ text ("+" ++ String.fromInt facepileOverflow) ] ]

                                else
                                    []
                               )
                        )
                    ]
                , div [ class "call-overlay-meta" ]
                    [ span
                        [ class
                            ("call-connection-dot"
                                ++ (if connected then
                                        " connected"

                                    else
                                        ""
                                   )
                            )
                        , attribute "aria-hidden" "true"
                        ]
                        []
                    , span [] [ text statusText ]
                    , span [ attribute "aria-hidden" "true" ] [ text "·" ]
                    , liveCallTimer "call-overlay-timer pw-live-call-timer" active.startTime
                    ]
                ]
            , button [ class "btn icon-btn call-minimize", title "Minimize call", onClick ToggleCallOverlay ]
                [ span [ class "call-minimize-icon", attribute "aria-hidden" "true" ] [] ]
            ]
        , if model.voice.screenShare then
            div [ class "call-sharing-row" ]
                [ callIcon "screen"
                , span [] [ text "You are sharing your screen" ]
                , button [ class "btn ghost", onClick StopScreenShare ] [ text "Stop" ]
                ]

          else
            text ""
        , div [ class "call-overlay-users" ]
            (if List.isEmpty active.users then
                [ div [ class "call-empty" ] [ text "Your call will appear here when someone joins." ] ]

             else
                List.map (renderCallUser model) active.users
            )
        , div [ class "call-input-panel" ]
            [ div [ class "call-input-heading" ]
                [ label [ for "call-microphone" ] [ text "Your microphone" ]
                , span
                    [ class
                        ("call-mic-status"
                            ++ (if model.voice.muted then
                                    " muted"

                                else
                                    ""
                               )
                        )
                    ]
                    [ text
                        (if model.voice.muted then
                            "Muted"

                         else
                            "Microphone on"
                        )
                    ]
                ]
            , select [ id "call-microphone", value model.selectedAudioInput, onInput SelectAudioInput ]
                (option [ value "", selected (model.selectedAudioInput == "") ] [ text "System default" ] :: List.map (\device -> option [ value device.id, selected (model.selectedAudioInput == device.id) ] [ text device.label ]) model.audioInputs)
            , div [ class "call-mic-meter", attribute "data-call-mic-meter" "true", attribute "role" "meter", attribute "aria-label" "Live microphone level", attribute "aria-valuemin" "0", attribute "aria-valuemax" "100", attribute "aria-valuenow" "0" ]
                [ span [ class "call-mic-fill" ] [] ]
            , Html.node "pw-input-volume" [] []
            ]
        , Html.node "pw-screen-settings" [] []
        , Html.node "details"
            [ class "call-health" ]
            [ Html.node "summary" [] [ text "Call health" ]
            , div [ attribute "data-call-health-list" "true" ] []
            , p [ class "call-health-privacy" ] [ text "Connection statistics only. No audio is recorded." ]
            ]
        , div [ class "call-tools" ]
            [ button [ class "btn ghost", onClick (BridgeEvent "open_voice_settings" E.null) ] [ span [ class "ui-icon ui-icon-settings", attribute "aria-hidden" "true" ] [], text "Audio settings" ]
            , button [ class "btn ghost", onClick (BridgeEvent "unlock_audio" E.null), title "Enable playback if your browser blocked call audio" ] [ text "Enable audio" ]
            ]
        , div [ class "call-overlay-controls", attribute "aria-label" "Call controls" ]
            [ control
                (if model.voice.muted then
                    "mic off"

                 else
                    "mic"
                )
                (if model.voice.muted then
                    "Unmute"

                 else
                    "Mute"
                )
                model.voice.muted
                (BridgeEvent "toggle_mute" E.null)
            , control
                (if model.voice.deafened then
                    "audio off"

                 else
                    "audio"
                )
                (if model.voice.deafened then
                    "Undeafen"

                 else
                    "Deafen"
                )
                model.voice.deafened
                (BridgeEvent "toggle_deafen" E.null)
            , control "screen"
                (if model.voice.screenShare then
                    "Stop share"

                 else
                    "Share"
                )
                model.voice.screenShare
                (if model.voice.screenShare then
                    StopScreenShare

                 else
                    StartScreenShare
                )
            , button [ class "call-control leave", onClick EndCall ] [ callIcon "hangup", span [] [ text "Leave" ] ]
            ]
        , button [ class "call-resize-handle", type_ "button", attribute "data-call-resize" "", attribute "aria-label" "Resize call window", title "Drag to resize; arrow keys resize when focused" ] [ text "↘" ]
        ]


renderCallUser : Model -> CallUser -> Html Msg
renderCallUser model u =
    let
        isSelf =
            Maybe.map .id model.me == Just u.userId

        muted =
            if isSelf then
                model.voice.muted

            else
                u.muted

        deafened =
            if isSelf then
                model.voice.deafened

            else
                u.deafened

        avatarClass =
            "small"
                ++ (if (u.connected || isSelf) && not muted then
                        " live"

                    else
                        ""
                   )

        statusText =
            if u.reconnecting then
                "Reconnecting"

            else if u.connectionFailed then
                "Audio connection failed"

            else if u.screen && u.screenAudio then
                "Sharing screen · audio included"

            else if u.screen then
                "Sharing screen"

            else if muted then
                "Muted"

            else if deafened then
                "Deafened"

            else if isSelf then
                "You · Connected"

            else if u.connected then
                "Connected to you"

            else
                "Connecting audio"

        retryButton =
            if u.connectionFailed && not isSelf then
                button [ class "btn secondary call-retry", onClick (RetryCallPeer u.userId) ] [ text "Retry audio" ]

            else
                text ""
    in
    div [ class "call-user-row", attribute "data-peer-id" (String.fromInt u.userId) ]
        [ button
            [ type_ "button"
            , class "call-user-identity"
            , onClick (ShowUserPopup u.userId)
            , title ("Open " ++ u.displayName ++ "'s profile")
            ]
            [ avatarImg u.avatarUrl u.displayName avatarClass
            , div [ class "call-user-info" ]
                [ span [ class "call-user-name" ] [ text u.displayName ]
                , span
                [ class
                    ("call-user-status"
                        ++ (if u.connectionFailed then
                                " failed"

                            else if u.reconnecting then
                                " reconnecting"

                            else if muted then
                                " muted"

                            else if deafened then
                                " deafened"

                            else
                                ""
                           )
                    )
                ]
                    [ text statusText ]
                ]
            ]
        , if u.screen && not isSelf then
            button
                [ class "btn secondary watch-screen"
                , attribute "data-watch-screen" (String.fromInt u.userId)
                , title
                    (if u.screenAudio then
                        "Watch screen; shared audio is included"

                     else
                        "Watch screen"
                    )
                , onClick (BridgeEvent "watch_screen" (E.int u.userId))
                ]
                [ text "Watch screen" ]

          else
            text ""
        , retryButton
        , if isSelf then
            text ""

          else
            Html.node "pw-user-volume" [ attribute "user-id" (String.fromInt u.userId), attribute "user-name" u.displayName ] []
        ]


renderApp : Model -> Html Msg
renderApp model =
    div [ class "layout", attribute "data-ui-version" "2.5.2", attribute "data-ui-revision" "interface-5" ]
        [ renderRail model
        , renderSideForRoute model
        , main_ [ class (mainClass model.active) ]
            [ renderTopbar model
            , div [ class (contentClass model.active) ] [ renderPage model ]
            ]
        , renderRightPanel model
        , div
            [ class
                ("drawer-overlay"
                    ++ (if model.sidebarOpen then
                            " open"

                        else
                            ""
                       )
                )
            , onClick CloseSidebar
            ]
            []
        , renderMobileNav model
        , renderServersSheet model
        , Lazy.lazy3 renderQuickNavigation model.convs model.servers model.currentServer
        , renderContextMenu model
        , renderModal model
        ]


mainClass : ActiveRoute -> String
mainClass active =
    case active of
        DmView _ ->
            "main route-chat"

        ChannelView _ ->
            "main route-chat"

        Settings ->
            "main route-settings"

        SourceHub ->
            "main route-source"

        _ ->
            "main"


contentClass : ActiveRoute -> String
contentClass active =
    case active of
        DmView _ ->
            "content chat-content"

        ChannelView _ ->
            "content chat-content"

        _ ->
            "content"


renderServersSheet : Model -> Html Msg
renderServersSheet model =
    if not model.serversSheetOpen then
        text ""

    else
        div [ class "servers-sheet", onClick CloseServersSheet ]
            [ div [ class "servers-sheet-card", stopClick ]
                [ div [ class "servers-sheet-head" ]
                    [ div []
                        [ h3 [] [ text "Servers" ]
                        , small [ class "muted" ] [ text (String.fromInt (List.length model.servers) ++ " joined") ]
                        ]
                    , button [ class "sheet-close", type_ "button", onClick CloseServersSheet, attribute "aria-label" "Close servers" ]
                        [ span [ class "call-icon call-icon-close", attribute "aria-hidden" "true" ] [] ]
                    ]
                , div [ class "servers-sheet-list" ]
                    (if List.isEmpty model.servers then
                        [ div [ class "empty" ] [ text "You have not joined a server yet." ] ]

                     else
                        List.map (\s -> serverSheetRow s model) model.servers
                    )
                , div [ class "servers-sheet-actions" ]
                    [ button [ class "btn secondary", onClick (Go "#new-server") ] [ text "Create server" ]
                    , button [ class "btn secondary", onClick (InviteModal 0) ] [ text "Join with Wire" ]
                    ]
                ]
            ]


serverSheetRow : Server -> Model -> Html Msg
serverSheetRow s model =
    let
        isActive =
            case model.active of
                ServerView id ->
                    id == s.id

                ChannelView _ ->
                    Maybe.map (.id << .server) model.currentServer == Just s.id

                VoiceChannelView _ ->
                    Maybe.map (.id << .server) model.currentServer == Just s.id

                _ ->
                    False
    in
    button
        [ type_ "button"
        , class
            ("server-sheet-row"
                ++ (if isActive then
                        " active"

                    else
                        ""
                   )
            )
        , onClick (Go ("#server/" ++ String.fromInt s.id))
        , onContextMenu (OpenServerCtx s)
        , attribute "aria-current"
            (if isActive then
                "page"

             else
                "false"
            )
        ]
        [ serverIcon s
        , div [ class "grow" ]
            [ b [] [ text s.name ]
            , small [] [ text (s.role ++ " · " ++ String.fromInt s.memberCount ++ " members") ]
            ]
        , notificationBadge (serverNotificationCount model s)
        ]


renderRail : Model -> Html Msg
renderRail model =
    let
        serverButtons =
            List.map (\server -> renderServerIcon server model) (List.take 8 model.servers)

        moreServers =
            if List.length model.servers > 8 then
                [ railBtn "servers" "More servers" model.serversSheetOpen ToggleServersSheet ]

            else
                []
    in
    nav [ class "rail", attribute "aria-label" "Main navigation" ]
        ([ button [ class ("mark" ++ (if model.active == SourceHub then " active" else "")), type_ "button", title (model.appName ++ " source architecture"), attribute "aria-label" (model.appName ++ " source architecture"), attribute "aria-current" (if model.active == SourceHub then "page" else "false"), onClick (Go "#source") ] []
         , railBtn "home" "Home" (model.active == Home) (Go "#")
         , railBtn "messages" "Direct messages" (isDmActive model) (Go "#dms")
         , railBtn "forums" "Forums" (model.active == Forums) (Go "#forums")
         , railBtn "friends" "Friends" (model.active == Friends) (Go "#friends")
         , div [ class "rail-divider", attribute "aria-hidden" "true" ] []
         ]
            ++ serverButtons
            ++ moreServers
            ++ [ div [ class "rail-spacer" ] []
               , railBtn "settings" "Settings" (model.active == Settings) (Go "#settings")
               ]
        )


railBtn : String -> String -> Bool -> Msg -> Html Msg
railBtn icon label active msg =
    button
        [ class
            ("rail-btn"
                ++ (if active then
                        " active"

                    else
                        ""
                   )
            )
        , onClick msg
        , title label
        , attribute "aria-label" label
        ]
        [ span [ class ("rail-glyph ui-icon ui-icon-" ++ icon), attribute "aria-hidden" "true" ] [] ]


isDmActive : Model -> Bool
isDmActive model =
    case model.active of
        Dms ->
            True

        DmView _ ->
            True

        _ ->
            False


renderServerIcon : Server -> Model -> Html Msg
renderServerIcon s model =
    let
        isActive =
            serverIsActive s model
    in
    button
        [ class
            ("rail-btn"
                ++ (if isActive then
                        " active"

                    else
                        ""
                   )
            )
        , onClick (Go ("#server/" ++ String.fromInt s.id))
        , onContextMenu (OpenServerCtx s)
        , title s.name
        , attribute "aria-label" (notificationLabel s.name (serverNotificationCount model s))
        , attribute "aria-current"
            (if isActive then
                "page"

             else
                "false"
            )
        ]
        [ serverIcon s
        , notificationBadge (serverNotificationCount model s)
        ]


serverIsActive : Server -> Model -> Bool
serverIsActive server model =
    case model.active of
        ServerView id ->
            id == server.id

        ChannelView _ ->
            Maybe.map .server model.currentServer == Just server

        VoiceChannelView _ ->
            Maybe.map .server model.currentServer == Just server

        _ ->
            False


channelNotificationCount : Model -> Int -> Int
channelNotificationCount model channelId =
    let
        url =
            "#/channel/" ++ String.fromInt channelId
    in
    model.notifs
        |> List.filter (\notification -> notification.url == url)
        |> List.length


serverNotificationCount : Model -> Server -> Int
serverNotificationCount model server =
    model.notifs
        |> List.filter (\notification -> notification.serverId == Just server.id)
        |> List.length


notificationLabel : String -> Int -> String
notificationLabel name count =
    if count == 0 then
        name

    else
        name ++ ", " ++ String.fromInt count ++ (if count == 1 then " notification" else " notifications")


notificationBadge : Int -> Html Msg
notificationBadge count =
    span
        [ class "badge rail-count"
        , attribute "data-zero"
            (if count == 0 then
                "1"

             else
                "0"
            )
        ]
        [ if count > 0 then
            text
                (if count > 99 then
                    "99"

                 else
                    String.fromInt count
                )

          else
            text ""
        ]


serverIcon : Server -> Html Msg
serverIcon s =
    if String.isEmpty s.iconUrl then
        div [ class "server-icon" ] [ text (String.left 1 (String.toUpper s.name)) ]

    else
        div [ class "server-icon", style "background-color" (avatarColor s.name) ]
            [ img
                [ src s.iconUrl
                , alt s.name
                , attribute "decoding" "async"
                , attribute "loading" "lazy"
                , attribute "fetchpriority" "low"
                , attribute "data-avatar-fallback" s.name
                , attribute "data-avatar-src" s.iconUrl
                ]
                []
            ]


renderSide : Model -> Html Msg
renderSide model =
    aside
        [ class
            ("side"
                ++ (if model.sidebarOpen then
                        " open"

                    else
                        ""
                   )
            )
        ]
        [ sideHead model
        , searchBox model
        , div [ class "list" ]
            ([ notifRow model
             , friendsRow model
             , dmHeader model
             , Html.node "pw-onboarding-entry" [ attribute "data-variant" "sidebar" ] []
             ]
                ++ (let
                        requestCount =
                            List.length (List.filter (\c -> c.requestState == "pending") model.convs)
                    in
                    if requestCount == 0 then
                        []

                    else
                        [ messageRequestsNav requestCount ]
                   )
                ++ List.map (\c -> convRow c model) (List.filter (\c -> c.requestState /= "pending") model.convs)
            )
        , userPanel model
        , Html.node "pw-sidebar-resize" [] []
        ]


renderSideForRoute : Model -> Html Msg
renderSideForRoute model =
    case ( model.active, model.currentServer ) of
        ( ServerView _, Just data ) ->
            renderServerSide model data

        ( ChannelView _, Just data ) ->
            renderServerSide model data

        ( VoiceChannelView _, Just data ) ->
            renderServerSide model data

        _ ->
            renderSide model


renderServerSide : Model -> ServerData -> Html Msg
renderServerSide model data =
    let
        textChannels =
            List.filter (\c -> c.kind /= "voice") data.channels

        voiceChannels =
            List.filter (\c -> c.kind == "voice") data.channels

        uncategorizedText =
            List.filter (\c -> c.categoryId == Nothing) textChannels

        uncategorizedVoice =
            List.filter (\c -> c.categoryId == Nothing) voiceChannels

        isCollapsed catId =
            Set.member catId model.collapsedCategories

        categoryBlock cat channels =
            [ div [ class "channel-group-title clickable", onClick (ToggleCategory cat.id) ]
                [ text
                    (if isCollapsed cat.id then
                        "▶ "

                     else
                        "▼ "
                    )
                , text cat.name
                , if canManageChannels then
                    span [ class "category-actions" ]
                        [ button [ class "ctx-trigger", type_ "button", title ("Add a channel to " ++ cat.name), onClickStop (ChannelModalInCategory data.server.id cat.id) ] [ text "+" ]
                        , button [ class "ctx-trigger", type_ "button", title ("Edit " ++ cat.name), onClickStop (EditCategoryModal data.server.id cat) ] [ text "⋯" ]
                        ]

                  else
                    text ""
                ]
            ]
                ++ (if isCollapsed cat.id then
                        []

                    else if List.isEmpty channels then
                        [ div [ class "category-empty" ] [ text "No channels yet" ] ]

                    else
                        List.map (managedChannelRow model canManageChannels data.categories) channels
                   )

        sortedCategories =
            List.sortBy .position data.categories

        canManageChannels =
            serverHasPermission 8 data.server

        canCreateWire =
            serverHasPermission 256 data.server
    in
    aside
        [ class
            ("side"
                ++ (if model.sidebarOpen then
                        " open"

                    else
                        ""
                   )
            )
        ]
        [ div [ class "side-head server-side-head" ]
            [ div [ class "side-title-row" ]
                [ div [ class "server-side-identity", onContextMenu (OpenServerCtx data.server) ]
                    [ serverIcon data.server
                    , div [ class "side-title-copy" ]
                        [ h1 [ title data.server.name ] [ text data.server.name ]
                        , small []
                            [ text
                                (if String.isEmpty data.server.description then
                                    "Server"

                                 else
                                    data.server.description
                                )
                            ]
                        ]
                    ]
                , button [ class "side-close", type_ "button", onClick CloseSidebar, attribute "aria-label" "Close navigation" ]
                    [ span [ class "call-icon call-icon-close", attribute "aria-hidden" "true" ] [] ]
                ]
            , div [ class "nav-actions" ]
                ([ button [ class "btn secondary", onClick (BridgeEvent "open_server_admin" (E.int data.server.id)) ] [ text "Server settings" ] ]
                    ++ (if canCreateWire then
                            [ button [ class "btn secondary", onClick (InviteModal data.server.id) ] [ text "Wire" ] ]

                        else
                            []
                       )
                    ++ (if canManageChannels then
                            [ button [ class "btn secondary", onClick (ChannelModal data.server.id) ] [ text "Channel" ]
                            , button [ class "btn secondary", onClick (CreateCategoryModal data.server.id) ] [ text "Category" ]
                            ]

                        else
                            []
                       )
                )
            ]
        , div [ class "search" ] [ quickJumpButton ]
        , div [ class "list server-channel-list" ]
            (channelGroup model "Text channels" uncategorizedText
                ++ channelGroup model "Voice channels" uncategorizedVoice
                ++ List.concatMap (\cat -> categoryBlock cat (List.filter (\c -> c.categoryId == Just cat.id) data.channels)) sortedCategories
            )
        , userPanel model
        , Html.node "pw-sidebar-resize" [] []
        ]


channelGroup : Model -> String -> List Channel -> List (Html Msg)
channelGroup model heading channels =
    if List.isEmpty channels then
        []

    else
        div [ class "channel-group-title" ] [ text heading ] :: List.map (channelRow model) channels


statusPreference : String -> String
statusPreference status =
    case status of
        "away" ->
            "away"

        "busy" ->
            "busy"

        "invisible" ->
            "invisible"

        _ ->
            "online"


renderRightPanel : Model -> Html Msg
renderRightPanel model =
    case ( model.active, model.currentServer ) of
        ( ServerView _, Just data ) ->
            renderMembersPanel model data

        ( ChannelView _, Just data ) ->
            renderMembersPanel model data

        ( VoiceChannelView _, Just data ) ->
            renderMembersPanel model data

        _ ->
            text ""


renderMembersPanel : Model -> ServerData -> Html Msg
renderMembersPanel model data =
    aside [ class "right members-panel" ]
        [ h3 [] [ text "Members" ]
        , div [ class "list" ] (List.map (\member -> memberRow model.userStatuses data.server.id member) data.members)
        ]


sideHead : Model -> Html Msg
sideHead model =
    div [ class "side-head" ]
        [ div [ class "side-title-row" ]
            [ div [ class "side-title-copy" ]
                [ h1 [] [ text model.appName ]
                , small [] [ text "A place for your people" ]
                ]
            , button [ class "side-close", type_ "button", onClick CloseSidebar, attribute "aria-label" "Close navigation" ]
                [ span [ class "call-icon call-icon-close", attribute "aria-hidden" "true" ] [] ]
            ]
        , Html.node "details"
            [ class "workspace-menu" ]
            [ Html.node "summary" [] [ text "Workspace", span [ attribute "aria-hidden" "true" ] [ text "⌄" ] ]
            , div [ class "workspace-menu-items" ]
                [ button [ class "btn secondary", onClick (Go "#new-server") ] [ text "Create server" ]
                , button [ class "btn secondary", onClick (InviteModal 0) ] [ text "Join with Wire" ]
                ]
            ]
        ]


quickJumpButton : Html Msg
quickJumpButton =
    button [ type_ "button", class "quick-jump-button", attribute "data-open-switcher" "", attribute "aria-label" "Quick switcher", title "Jump to a conversation or server (Ctrl+K / ⌘K)" ]
        [ span [ class "ui-icon ui-icon-search", attribute "aria-hidden" "true" ] []
        , span [] [ text "Jump to…" ]
        , kbd [] [ text "Ctrl K" ]
        ]


renderQuickNavigation : List Conversation -> List Server -> Maybe ServerData -> Html Msg
renderQuickNavigation conversations servers currentServer =
    let
        item name detail route =
            E.object [ ( "name", E.string name ), ( "detail", E.string detail ), ( "href", E.string route ) ]

        rooms =
            currentServer
                |> Maybe.map (\data -> List.map (\channel -> item channel.name (data.server.name ++ " · " ++ channel.kind) ("#channel/" ++ String.fromInt channel.id)) (List.filter (\channel -> channel.kind /= "voice") data.channels))
                |> Maybe.withDefault []
    in
    Html.node "pw-quick-switcher"
        [ attribute "items"
            (E.encode 0
                (E.list identity
                    (List.map (\c -> item (convName c) "Conversation" ("#dm/" ++ String.fromInt c.id)) conversations
                        ++ List.map (\server -> item server.name "Server" ("#server/" ++ String.fromInt server.id)) servers
                        ++ rooms
                        ++ [ item "Home" "Overview" "#home", item "Friends" "People" "#friends", item "Plainwire Source" "Architecture and development" "#source", item "Settings" "Personal preferences" "#settings", item "Notifications" "Activity" "#notifications" ]
                    )
                )
            )
        ]
        []


searchBox : Model -> Html Msg
searchBox _ =
    div [ class "search" ]
        [ quickJumpButton
        , input
            [ id "globalSearch"
            , placeholder "Search all of Plainwire"
            , attribute "aria-label" "Search all of Plainwire"
            , onInput (\s -> SearchQuery s)
            , on "keydown"
                (D.andThen
                    (\k ->
                        if k == "Enter" then
                            D.succeed DoSearch

                        else
                            D.fail "no"
                    )
                    (D.field "key" D.string)
                )
            ]
            []
        ]


notifRow : Model -> Html Msg
notifRow model =
    let
        unread =
            List.length (List.filter (\n -> not n.seen) model.notifs)
    in
    a [ class "row", href "#notifications", onClick (Go "#notifications") ]
        [ span [ class "nav-symbol", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-notifications" ] [] ]
        , div [ class "grow" ]
            [ b [] [ text "Notifications" ]
            , small [ class "muted" ] [ text "Mentions and activity" ]
            ]
        , span
            [ class "badge"
            , if unread == 0 then
                attribute "data-zero" "1"

              else
                attribute "data-zero" "0"
            ]
            [ if unread > 0 then
                text (String.fromInt unread)

              else
                text ""
            ]
        ]


friendsRow : Model -> Html Msg
friendsRow model =
    let
        pending =
            List.length (List.filter (\f -> f.incoming) model.friends)
    in
    a [ class "row", href "#friends", onClick (Go "#friends") ]
        [ span [ class "nav-symbol", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-friends" ] [] ]
        , div [ class "grow" ]
            [ b [] [ text "Friends" ], small [ class "muted" ] [ text "Requests and contacts" ] ]
        , if pending > 0 then
            span [ class "badge" ] [ text (String.fromInt pending) ]

          else
            text ""
        ]


serverRow : Server -> Model -> Html Msg
serverRow s model =
    let
        isActive =
            case model.active of
                ServerView id ->
                    id == s.id

                _ ->
                    False
    in
    a
        [ class
            ("row"
                ++ (if isActive then
                        " active"

                    else
                        ""
                   )
            )
        , href ("#server/" ++ String.fromInt s.id)
        , onClick (Go ("#server/" ++ String.fromInt s.id))
        ]
        [ serverIcon s
        , div [ class "grow" ]
            [ b [] [ text s.name ]
            , small [ class "muted" ] [ text (s.role ++ " · " ++ String.fromInt s.memberCount ++ " members") ]
            ]
        ]


dmHeader : Model -> Html Msg
dmHeader model =
    div [ class "side-section-heading" ]
        [ div [ class "grow" ]
            [ b [] [ text "Direct messages" ]
            , small [ class "muted" ] [ text "private and group chats" ]
            ]
        , button [ class "btn", onClick NewDmModal ] [ text "New" ]
        ]


conversationPreviewSummary : String -> String
conversationPreviewSummary source =
    let
        lines =
            String.lines source

        isAttachmentLine rawLine =
            let
                line =
                    String.trim rawLine
            in
            (String.startsWith "![" line || String.startsWith "[" line)
                && (String.contains "](/api/files/" line || String.contains "](/api/media/" line)

        attachmentCount =
            lines |> List.filter isAttachmentLine |> List.length

        plain =
            lines
                |> List.filter (not << isAttachmentLine)
                |> String.join " "
                |> String.words
                |> String.join " "

        clipped =
            if String.length plain > 120 then
                String.left 117 plain ++ "…"

            else
                plain

        attachmentLabel =
            if attachmentCount == 1 then
                "1 attachment"

            else if attachmentCount > 1 then
                String.fromInt attachmentCount ++ " attachments"

            else
                ""
    in
    if String.isEmpty clipped then
        attachmentLabel

    else if String.isEmpty attachmentLabel then
        clipped

    else
        clipped ++ " · " ++ attachmentLabel


conversationSenderLabel : Model -> Conversation -> String
conversationSenderLabel model conversation =
    if conversation.lastMessageId == Nothing || conversation.lastSenderId == 0 then
        ""

    else if Maybe.map .id model.me == Just conversation.lastSenderId then
        "You: "

    else if String.isEmpty conversation.lastSenderName then
        if String.isEmpty conversation.lastSenderUsername then
            ""

        else
            "@" ++ conversation.lastSenderUsername ++ ": "

    else
        conversation.lastSenderName ++ ": "


messageRequestsNav : Int -> Html Msg
messageRequestsNav count =
    a [ class "row message-requests-nav", href "#dms", onClick (Go "#dms") ]
        [ span [ class "nav-symbol", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-messages" ] [] ]
        , div [ class "grow" ] [ b [] [ text "Message requests" ], small [ class "muted" ] [ text "Review before replying" ] ]
        , span [ class "badge" ] [ text (String.fromInt count) ]
        ]


convRow : Conversation -> Model -> Html Msg
convRow c model =
    let
        isActive =
            case model.active of
                DmView id ->
                    id == c.id

                _ ->
                    False

        lastText =
            Maybe.withDefault "No messages yet" c.lastBody

        senderLabel =
            conversationSenderLabel model c
    in
    a
        [ class
            ("row dm-row"
                ++ (if isActive then
                        " active"

                    else
                        ""
                   )
                ++ (if c.unread > 0 then
                        " unread"

                    else
                        ""
                   )
            )
        , href ("#dm/" ++ String.fromInt c.id)
        , onClick (Go ("#dm/" ++ String.fromInt c.id))
        , onContextMenu (OpenConvCtx c)
        ]
        [ convAvatar model c
        , div [ class "grow" ]
            [ div [ class "dm-row-head" ]
                [ b [] [ text (convName c) ]
                , if Set.member ("dm:" ++ String.fromInt c.id) model.mentionHints then
                    span [ class "pill mention-chip" ] [ text "mentioned you" ]

                  else
                    text ""
                , small [ class "muted" ] [ text (agoAt model.serverTime c.updatedAt) ]
                ]
            , div [ class "muted dm-preview" ]
                [ if String.isEmpty senderLabel then
                    text ""

                  else
                    strong [ class "dm-preview-sender" ] [ text senderLabel ]
                , text (conversationPreviewSummary lastText)
                ]
            ]
        , span [ class "dm-row-actions" ]
            [ span
                [ class "badge"
                , if c.unread == 0 then
                    attribute "data-zero" "1"

                  else
                    attribute "data-zero" "0"
                ]
                [ if c.unread > 0 then
                    text (String.fromInt c.unread)

                  else
                    text ""
                ]
            , if c.memberCount == 2 then
                span
                    [ class "dm-close"
                    , attribute "role" "button"
                    , attribute "tabindex" "0"
                    , title "Close DM"
                    , onClickStop (CloseConversation c.id)
                    ]
                    [ text "×" ]

              else
                text ""
            ]
        ]


convName : Conversation -> String
convName c =
    if not (String.isEmpty c.name) then
        c.name

    else if c.memberCount == 2 && not (String.isEmpty c.peerName) then
        c.peerName

    else
        "Group DM " ++ String.fromInt c.id


convAvatar : Model -> Conversation -> Html Msg
convAvatar model c =
    if not (String.isEmpty c.avatarUrl) then
        avatarImgWithLoading "lazy" c.avatarUrl (convName c) ""

    else if c.memberCount == 2 then
        presenceAvatar model.userStatuses c.peerId c.peerAvatarUrl (convName c) ""

    else
        div [ class "avatar group-avatar" ] [ text (String.fromInt c.memberCount) ]


userPanel : Model -> Html Msg
userPanel model =
    case model.me of
        Just u ->
            let
                liveStatus =
                    Dict.get (String.fromInt u.id) model.userStatuses
                        |> Maybe.withDefault
                            (if model.wsConnected then
                                model.profileStatus

                             else
                                "offline"
                            )
            in
            div [ class "user-panel" ]
                [ div [ class "presence-avatar", title (statusDisplayName liveStatus), attribute "aria-label" (u.displayName ++ "  -  " ++ statusDisplayName liveStatus) ]
                    [ avatarImgWithLoading "eager" u.avatarUrl u.displayName ""
                    , span [ class ("avatar-presence-dot " ++ liveStatus), attribute "aria-hidden" "true" ] []
                    ]
                , div [ class "grow" ]
                    [ b [] [ text u.displayName ]
                    , small [] [ text (statusDisplayName liveStatus) ]
                    ]
                , div [ class "user-panel-actions" ]
                    [ button [ title "Settings", attribute "aria-label" "Settings", onClick (Go "#settings") ] [ span [ class "ui-icon ui-icon-settings", attribute "aria-hidden" "true" ] [] ] ]
                ]

        Nothing ->
            text ""


statusDisplayName : String -> String
statusDisplayName status =
    case status of
        "online" ->
            "Online"

        "away" ->
            "Away"

        "busy" ->
            "Do not disturb"

        "invisible" ->
            "Invisible"

        _ ->
            "Offline"


renderMobileNav : Model -> Html Msg
renderMobileNav model =
    let
        unreadDms =
            List.sum (List.map .unread model.convs)

        unreadNotifs =
            List.length (List.filter (\notification -> not notification.seen) model.notifs)

        pendingFriends =
            List.length (List.filter .incoming model.friends)
    in
    nav [ class "mobile-nav", attribute "aria-label" "Primary navigation" ]
        [ mobileBtn "home" "Home" (model.active == Home) (Go "#") unreadNotifs
        , mobileBtn "messages" "Messages" (isDmActive model) (Go "#dms") unreadDms
        , mobileBtn "servers" "Servers" (model.serversSheetOpen || isServerRoute model.active) ToggleServersSheet 0
        , mobileBtn "friends" "Friends" (model.active == Friends) (Go "#friends") pendingFriends
        , mobileBtn "profile" "You" (model.active == Settings || isProfileRoute model.active) (Go "#settings") 0
        ]


isServerRoute : ActiveRoute -> Bool
isServerRoute route =
    case route of
        ServerView _ ->
            True

        ChannelView _ ->
            True

        VoiceChannelView _ ->
            True

        _ ->
            False


isProfileRoute : ActiveRoute -> Bool
isProfileRoute route =
    case route of
        ProfileView _ ->
            True

        _ ->
            False


mobileBtn : String -> String -> Bool -> Msg -> Int -> Html Msg
mobileBtn icon label active msg badgeCount =
    button
        [ class
            ("mobile-nav-btn"
                ++ (if active then
                        " active"

                    else
                        ""
                   )
            )
        , onClick msg
        , attribute "aria-label"
            (label
                ++ (if badgeCount > 0 then
                        ", " ++ String.fromInt badgeCount ++ " new"

                    else
                        ""
                   )
            )
        ]
        [ span [ class "mobile-nav-icon-wrap" ]
            [ span [ class ("mobile-nav-icon ui-icon ui-icon-" ++ icon), attribute "aria-hidden" "true" ] []
            , if badgeCount > 0 then
                span [ class "mobile-nav-badge", attribute "aria-hidden" "true" ]
                    [ text
                        (if badgeCount > 99 then
                            "99+"

                         else
                            String.fromInt badgeCount
                        )
                    ]

              else
                text ""
            ]
        , span [ class "mobile-nav-label" ] [ text label ]
        ]


renderTopbar : Model -> Html Msg
renderTopbar model =
    div [ class "topbar" ]
        [ button [ class "sidebar-toggle", onClick ToggleSidebar, attribute "aria-label" "Open navigation" ]
            [ span [ class "ui-icon ui-icon-menu", attribute "aria-hidden" "true" ] [] ]
        , div [ class "topbar-title" ]
            [ h2 [] [ text (topbarTitle model) ]
            , small [ class "muted" ] [ text (topbarSubtitle model) ]
            ]
        , if model.wsConnected then
            text ""

          else
            div [ class "topbar-connection reconnecting", attribute "role" "status" ]
                [ span [ class "topbar-connection-dot", attribute "aria-hidden" "true" ] []
                , span [] [ text "Reconnecting" ]
                ]
        ]


topbarSubtitle : Model -> String
topbarSubtitle model =
    case model.active of
        Home ->
            "Overview"

        Forums ->
            "Forum discussions"

        ForumView _ ->
            "Forum"

        ThreadView _ ->
            "Discussion"

        Dms ->
            "Private conversations"

        DmView _ ->
            "Direct conversation"

        Friends ->
            "Contacts and requests"

        ProfileView _ ->
            "User profile"

        Settings ->
            "Preferences"

        NewServer ->
            "New forum"

        ServerView _ ->
            "Server overview"

        ChannelView _ ->
            "Text channel"

        VoiceChannelView _ ->
            "Voice channel"

        InviteView _ ->
            "Server Wire"

        Notifications ->
            "Mentions and activity"

        SourceHub ->
            "Live source architecture and development"

        SearchView _ ->
            "Search results"


topbarTitle : Model -> String
topbarTitle model =
    case model.active of
        Home ->
            "Home"

        Forums ->
            "Forums"

        ForumView _ ->
            "Forum"

        ThreadView _ ->
            "Thread"

        Dms ->
            "Direct Messages"

        DmView _ ->
            "Direct Message"

        Friends ->
            "Friends"

        ProfileView _ ->
            "Profile"

        Settings ->
            "Settings"

        NewServer ->
            "Create server"

        ServerView _ ->
            "Server"

        ChannelView _ ->
            "Channel"

        VoiceChannelView _ ->
            "Voice"

        InviteView _ ->
            "Wire"

        Notifications ->
            "Notifications"

        SourceHub ->
            "Plainwire Source"

        SearchView _ ->
            "Search"


renderPage : Model -> Html Msg
renderPage model =
    case model.active of
        Home ->
            Home.view
                { conversationRow = \conversation -> convRow conversation model
                , navigate = Go
                , newMessage = NewDmModal
                , newServer = Go "#new-server"
                , openServers = ToggleServersSheet
                , relativeTime = relativeTime
                , sortConversations = sortConvs
                }
                model

        Forums ->
            renderForumsPage model

        ForumView id ->
            renderForumPage id model

        ThreadView id ->
            renderThreadPage id model

        Dms ->
            renderDmsPage model

        DmView id ->
            renderMessagePage ("direct:" ++ String.fromInt id) "Message conversation" model

        Friends ->
            renderFriendsPage model

        ProfileView id ->
            renderProfilePage model

        Settings ->
            renderSettingsPage model

        NewServer ->
            renderNewServerPage model

        ServerView id ->
            renderServerPage model

        ChannelView id ->
            renderMessagePage ("channel:" ++ String.fromInt id) "Message channel" model

        VoiceChannelView id ->
            renderVoicePage id model

        InviteView _ ->
            renderInvitePage model

        Notifications ->
            Notifications.view relativeTime model

        SourceHub ->
            div [ class "source-hub-page" ]
                [ Html.node "pw-source-hub" []
                    [ div [ class "source-hub-fallback card pad" ]
                        [ h3 [] [ text "Loading Plainwire source architecture…" ]
                        , p [ class "muted" ] [ text "Live development data is loaded securely through this Plainwire instance." ]
                        ]
                    ]
                ]

        SearchView q ->
            renderSearchPage q model


renderForumsPage : Model -> Html Msg
renderForumsPage model =
    let
        filtered =
            if String.isEmpty (String.trim model.searchQuery) then
                model.forums

            else
                let
                    q =
                        String.toLower (String.trim model.searchQuery)
                in
                List.filter
                    (\f ->
                        String.contains q (String.toLower f.name)
                            || String.contains q (String.toLower f.description)
                    )
                    model.forums

        myForums =
            List.filter .joined filtered

        otherForums =
            List.filter (\f -> not f.joined) filtered
    in
    div [ class "forum-page" ]
        [ div [ class "forum-header-bar forum-directory-hero" ]
            [ div [ class "forum-header-title" ]
                [ span [ class "eyebrow" ] [ text "Plainwire Forums" ]
                , h2 [] [ text "Find a forum" ]
                , p [ class "muted" ] [ text (String.fromInt (List.length model.forums) ++ " forums for questions, ideas, and conversation") ]
                ]
            , div [ class "forum-header-actions" ]
                [ button [ class "btn", onClick NewForumModal ] [ text "Create Forum" ]
                ]
            ]
        , div [ class "forum-search" ]
            [ input
                [ class "forum-search-input"
                , value model.searchQuery
                , placeholder "Search forums..."
                , onInput SearchQuery
                , on "keydown"
                    (D.andThen
                        (\k ->
                            if k == "Enter" then
                                D.succeed DoSearch

                            else
                                D.fail "no"
                        )
                        (D.field "key" D.string)
                    )
                ]
                []
            , span [ class "forum-search-icon", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-search" ] [] ]
            ]
        , if List.isEmpty filtered then
            div [ class "empty" ]
                [ text
                    (if String.isEmpty model.searchQuery then
                        "No forums yet."

                     else
                        "No forums match your search."
                    )
                ]

          else
            div []
                [ if not (List.isEmpty myForums) then
                    div []
                        [ h3 [ class "forum-section-title" ] [ text "My Communities" ]
                        , div [ class "forum-grid" ] (List.map (forumCard model) myForums)
                        ]

                  else
                    text ""
                , if not (List.isEmpty otherForums) then
                    div []
                        [ h3 [ class "forum-section-title" ] [ text "Other Communities" ]
                        , div [ class "forum-grid" ] (List.map (forumCard model) otherForums)
                        ]

                  else
                    text ""
                ]
        ]


forumCard : Model -> Forum -> Html Msg
forumCard model f =
    let
        memberText =
            String.fromInt f.memberCount
                ++ " member"
                ++ (if f.memberCount /= 1 then
                        "s"

                    else
                        ""
                   )

        threadText =
            String.fromInt f.threadCount
                ++ " thread"
                ++ (if f.threadCount /= 1 then
                        "s"

                    else
                        ""
                   )
    in
    div [ class "forum-card" ]
        [ div [ class "forum-card-top", onClick (Go ("#f/" ++ String.fromInt f.id)) ]
            [ span [ class "forum-card-icon" ] [ text (String.left 1 (String.toUpper f.name)) ]
            , div [ class "forum-card-info" ]
                [ span [ class "forum-card-kicker" ] [ text ("f/" ++ f.slug) ]
                , h3 [ class "forum-card-name" ] [ text f.name ]
                , p [ class "forum-card-desc" ] [ text (ellipsize 120 f.description) ]
                ]
            ]
        , div [ class "forum-card-stats" ]
            [ span [ class "forum-stat" ] [ text memberText ]
            , span [ class "forum-stat" ] [ text threadText ]
            , span [ class "forum-stat" ] [ text ("last " ++ Maybe.withDefault "never" (Maybe.map (ago model.serverTime) f.lastAt)) ]
            ]
        , div [ class "forum-card-footer" ]
            [ if f.joined then
                button [ class "btn forum-joined-btn", onClick (LeaveForum f.id) ] [ text "Joined" ]

              else
                button [ class "btn forum-join-btn", onClick (JoinForum f.id) ] [ text "Join" ]
            , a [ class "forum-card-link", href ("#f/" ++ String.fromInt f.id) ] [ text "View →" ]
            ]
        ]


renderForumPage : Int -> Model -> Html Msg
renderForumPage id model =
    let
        forum =
            List.filter (\f -> f.id == id) model.forums |> List.head
    in
    div [ class "forum-page" ]
        [ case forum of
            Just f ->
                div [ class "forum-view-header" ]
                    [ div [ class "forum-view-title" ]
                        [ span [ class "forum-card-icon large" ] [ text (String.left 1 (String.toUpper f.name)) ]
                        , div []
                            [ span [ class "forum-card-kicker" ] [ text ("f/" ++ f.slug) ]
                            , h2 [] [ text f.name ]
                            , p [ class "muted" ] [ text f.description ]
                            , div [ class "forum-view-stats" ]
                                [ span [ class "forum-stat" ] [ text (String.fromInt f.memberCount ++ " members") ]
                                , span [ class "forum-stat" ] [ text (String.fromInt f.threadCount ++ " threads") ]
                                ]
                            ]
                        ]
                    , div [ class "forum-view-actions" ]
                        [ if f.ownerId == Maybe.map .id model.me then
                            span [ class "pill forum-owner-pill" ] [ text "Owner" ]

                          else if f.joined then
                            button [ class "btn forum-joined-btn", onClick (LeaveForum f.id) ] [ text "Joined" ]

                          else
                            button [ class "btn forum-join-btn", onClick (JoinForum f.id) ] [ text "Join" ]
                        , if f.joined then
                            button [ class "btn", onClick (NewThreadModal (Just id)) ] [ text "New Thread" ]

                          else
                            button [ class "btn secondary", disabled True, title "Join this forum to create a thread" ] [ text "Join to post" ]
                        , if f.ownerId == Maybe.map .id model.me then
                            button [ class "btn danger", onClick (BridgeEvent "delete_forum" (E.int f.id)) ] [ text "Delete Forum" ]

                          else
                            text ""
                        ]
                    ]

            Nothing ->
                div [ class "forum-view-header" ]
                    [ h2 [] [ text "Forum" ] ]
        , div [ class "thread-listing" ]
            (List.map (threadRow model) model.threads
                |> (\l ->
                        if List.isEmpty l then
                            [ div [ class "empty" ] [ text "No threads yet. Be the first to post!" ] ]

                        else
                            l
                   )
            )
        ]


threadRow : Model -> ForumThread -> Html Msg
threadRow model t =
    div [ class "forum-thread", onClick (Go ("#t/" ++ String.fromInt t.id)) ]
        [ voteColumn t
        , div [ class "thread-content" ]
            [ h3 [ class "thread-title" ]
                ((if t.pinned then
                    [ span [ class "pill pin" ] [ text "pinned" ], text " " ]

                  else
                    []
                 )
                    ++ (if t.score >= 5 || t.replyCount > 10 then
                            [ span [ class "pill hot" ] [ text "hot" ], text " " ]

                        else
                            []
                       )
                    ++ [ text t.title ]
                )
            , div [ class "thread-meta" ]
                [ avatarImg t.avatarUrl t.displayName "tiny"
                , span [ class "thread-author" ] [ text t.displayName ]
                , span [] [ text ("posted " ++ ago model.serverTime t.createdAt ++ " ago") ]
                ]
            , if String.isEmpty (String.trim t.body) then
                text ""

              else
                p [ class "thread-excerpt" ] [ text (ellipsize 240 t.body) ]
            , div [ class "thread-actions" ]
                [ span [ class "thread-action primary" ] [ text (String.fromInt t.replyCount ++ " replies") ]
                , span [ class "thread-action" ] [ text (String.fromInt t.views ++ " views") ]
                , span [ class "thread-action" ] [ text ("updated " ++ ago model.serverTime t.updatedAt ++ " ago") ]
                ]
            ]
        ]


renderThreadPage : Int -> Model -> Html Msg
renderThreadPage threadId model =
    case model.currentThread of
        Just t ->
            let
                canDelete =
                    t.canDelete

                canEdit =
                    t.canEdit

                canModerate =
                    t.canModerate
            in
            div [ class "thread-page" ]
                [ div [ class "thread-breadcrumb" ]
                    [ a [ href ("#f/" ++ String.fromInt t.forumId) ] [ text ("f/" ++ t.forumName) ]
                    , span [] [ text "›" ]
                    , span [] [ text ("t/" ++ String.fromInt t.id) ]
                    ]
                , div [ class "post card thread-post" ]
                    [ voteColumn t
                    , div [ class "post-body" ]
                        [ h1 [ class "thread-title" ] [ text t.title ]
                        , div [ class "post-meta" ]
                            [ avatarImg t.avatarUrl t.displayName ""
                            , div [ class "post-author-block" ]
                                [ b [] [ text t.displayName ]
                                , span [ class "muted" ] [ text ("@" ++ t.username ++ " · " ++ ago model.serverTime t.createdAt ++ " ago") ]
                                ]
                            ]
                        , div [ class "thread-post-body" ] (Markdown.renderBody t.body)
                        , div [ class "thread-post-footer" ]
                            [ span [] [ text (String.fromInt t.score ++ " points") ]
                            , span [] [ text (String.fromInt t.views ++ " views") ]
                            , span [] [ text (String.fromInt t.replyCount ++ " replies") ]
                            , if canEdit then
                                button [ class "thread-action-btn", onClick (BridgeEvent "edit_thread" (E.object [ ( "id", E.int t.id ), ( "title", E.string t.title ), ( "body", E.string t.body ), ( "raw_body", E.string t.rawBody ) ])) ] [ text "Edit" ]

                              else
                                text ""
                            , if canModerate then
                                button [ class "thread-action-btn", onClick (BridgeEvent "moderate_thread" (E.object [ ( "id", E.int t.id ), ( "action", E.string "pin" ), ( "value", E.bool (not t.pinned) ) ])) ] [ text (if t.pinned then "Unpin" else "Pin") ]

                              else
                                text ""
                            , if canModerate then
                                button [ class "thread-action-btn", onClick (BridgeEvent "moderate_thread" (E.object [ ( "id", E.int t.id ), ( "action", E.string "lock" ), ( "value", E.bool (not t.locked) ) ])) ] [ text (if t.locked then "Unlock" else "Lock") ]

                              else
                                text ""
                            , if canDelete then
                                button [ class "thread-delete-btn", onClick (BridgeEvent "delete_thread" (E.object [ ( "id", E.int t.id ), ( "forum_id", E.int t.forumId ) ])) ] [ text "Delete thread" ]

                              else
                                text ""
                            ]
                        ]
                    ]
                , div [ class "replies-head" ]
                    [ h2 [] [ text "Replies" ]
                    , span [ class "pill" ] [ text (String.fromInt (List.length model.replies) ++ " total") ]
                    ]
                , div [ id "replies", class "reply-stack" ]
                    (if List.isEmpty model.replies then
                        [ div [ class "empty" ] [ text "No replies yet. Be the first to add one." ] ]

                     else
                        List.indexedMap (replyView model) model.replies
                    )
                , if t.locked then
                    div [ class "locked-banner" ] [ text "This thread is locked. New replies are disabled." ]

                  else if t.viewerJoined then
                    Composer.view ("thread:" ++ String.fromInt threadId) "Reply to thread" model

                  else
                    div [ class "thread-membership-gate" ]
                        [ span [] [ text "Join this forum to reply or vote." ]
                        , button [ class "btn", onClick (JoinForum t.forumId) ] [ text "Join forum" ]
                        ]
                ]

        Nothing ->
            div [ class "empty" ] [ text "Loading thread..." ]


voteColumn : ForumThread -> Html Msg
voteColumn t =
    let
        upValue =
            if t.userVote == 1 then
                0

            else
                1

        downValue =
            if t.userVote == -1 then
                0

            else
                -1
    in
    div [ class "vote-column" ]
        [ button
            [ class
                ("vote-btn up"
                    ++ (if t.userVote == 1 then
                            " active"

                        else
                            ""
                       )
                )
            , title (if t.viewerJoined then "Upvote" else "Join this forum to vote")
            , disabled (not t.viewerJoined)
            , onClickStop (if t.viewerJoined then VoteThread t.id upValue else NoOp)
            ]
            [ text "▲" ]
        , span [ class "vote-count" ] [ text (String.fromInt t.score) ]
        , button
            [ class
                ("vote-btn down"
                    ++ (if t.userVote == -1 then
                            " active"

                        else
                            ""
                       )
                )
            , title (if t.viewerJoined then "Downvote" else "Join this forum to vote")
            , disabled (not t.viewerJoined)
            , onClickStop (if t.viewerJoined then VoteThread t.id downValue else NoOp)
            ]
            [ text "▼" ]
        ]


replyView : Model -> Int -> Reply -> Html Msg
replyView model idx r =
    let
        canEdit =
            r.canEdit

        canDelete =
            r.canDelete
    in
    div [ class "post card forum-reply" ]
        [ div [ class "reply-rail" ]
            [ avatarImg r.avatarUrl r.displayName ""
            , span [ class "reply-rail-line" ] []
            ]
        , div [ class "reply-content" ]
            [ div [ class "post-meta reply-meta" ]
                [ b [] [ text r.displayName ]
                , span [ class "reply-username" ] [ text ("@" ++ r.username) ]
                , span [ class "muted" ] [ text (ago model.serverTime r.createdAt ++ " ago") ]
                , span [ class "reply-number" ] [ text ("#" ++ String.fromInt (idx + 1)) ]
                ]
            , div [ class "reply-body" ] (Markdown.renderBody r.body)
            , if canEdit || canDelete then
                div [ class "reply-actions" ]
                    [ if canEdit then
                        button [ class "thread-action-btn", onClick (BridgeEvent "edit_thread_reply" (E.object [ ( "id", E.int r.id ), ( "thread_id", E.int r.threadId ), ( "body", E.string r.body ), ( "raw_body", E.string r.rawBody ) ])) ] [ text "Edit" ]

                      else
                        text ""
                    , if canDelete then
                        button [ class "thread-delete-btn", onClick (BridgeEvent "delete_thread_reply" (E.object [ ( "id", E.int r.id ), ( "thread_id", E.int r.threadId ) ])) ] [ text "Delete" ]

                      else
                        text ""
                    ]

              else
                text ""
            ]
        ]


renderDmsPage : Model -> Html Msg
renderDmsPage model =
    let
        requests =
            List.filter (\c -> c.requestState == "pending") model.convs

        conversations =
            List.filter (\c -> c.requestState /= "pending") model.convs

        unread =
            List.sum (List.map .unread conversations)
    in
    div [ class "dm-inbox page-stack" ]
        [ div [ class "page-heading" ]
            [ div []
                [ span [ class "eyebrow" ] [ text "Messages" ]
                , h1 [] [ text "Direct messages" ]
                , p [ class "muted" ]
                    [ text
                        (if unread > 0 then
                            String.fromInt unread ++ " unread across " ++ String.fromInt (List.length conversations) ++ " conversations."

                         else
                            String.fromInt (List.length conversations) ++ " conversations, all caught up."
                        )
                    ]
                ]
            , button [ class "btn", onClick NewDmModal ] [ text "New message" ]
            ]
        , Html.node "pw-onboarding-entry" [ attribute "data-variant" "inbox" ] []
        , if List.isEmpty requests then
            text ""

          else
            section [ class "dm-request-section" ]
                [ div [ class "section-head compact-section-head" ]
                    [ div []
                        [ h2 [] [ text "Message requests" ]
                        , p [ class "muted" ] [ text (String.fromInt (List.length requests) ++ " waiting for review") ]
                        ]
                    ]
                , div [ class "card dm-list-card" ] (List.map (messageRequestRow model) requests)
                ]
        , section [ class "dm-message-section" ]
            [ div [ class "section-head compact-section-head" ]
                [ div []
                    [ h2 [] [ text "Conversations" ]
                    , p [ class "muted" ] [ text "Private and group chats." ]
                    ]
                ]
            , div [ class "card dm-list-card" ]
                (if List.isEmpty conversations then
                    [ div [ class "empty dm-empty" ]
                        [ h2 [] [ text "No messages yet" ]
                        , p [] [ text "Start a conversation from Friends or create a new message." ]
                        , button [ class "btn", onClick NewDmModal ] [ text "Start a conversation" ]
                        ]
                    ]

                 else
                    List.map (\c -> convRow c model) conversations
                )
            ]
        ]


messageRequestRow : Model -> Conversation -> Html Msg
messageRequestRow model conversation =
    div [ class "row dm-row message-request-row" ]
        [ convAvatar model conversation
        , div [ class "grow" ]
            [ b [] [ text (convName conversation) ]
            , small [ class "muted dm-preview" ]
                [ if String.isEmpty (conversationSenderLabel model conversation) then
                    text ""

                  else
                    strong [ class "dm-preview-sender" ] [ text (conversationSenderLabel model conversation) ]
                , text (conversation.lastBody |> Maybe.map conversationPreviewSummary |> Maybe.withDefault "Wants to message you")
                ]
            ]
        , div [ class "request-actions" ]
            [ button [ class "btn", onClick (BridgeEvent "accept_message_request" (E.int conversation.id)) ] [ text "Accept" ]
            , button [ class "btn secondary", onClick (BridgeEvent "deny_message_request" (E.int conversation.id)) ] [ text "Delete" ]
            ]
        ]


renderFriendsPage : Model -> Html Msg
renderFriendsPage model =
    let
        incoming =
            List.filter .incoming model.friends

        outgoing =
            List.filter .outgoing model.friends

        accepted =
            List.filter (\f -> f.status == "accepted") model.friends

        blocked =
            List.filter (\f -> f.status == "blocked") model.friends

        online =
            List.filter
                (\f ->
                    case Dict.get (String.fromInt f.user.id) model.userStatuses of
                        Just "online" ->
                            True

                        Just "away" ->
                            True

                        Just "busy" ->
                            True

                        _ ->
                            False
                )
                accepted

        pendingCount =
            List.length incoming + List.length outgoing

        visible =
            if model.friendsTab == "online" then
                online

            else
                accepted

        listTitle =
            if model.friendsTab == "online" then
                "Online"

            else
                "All friends"
    in
    div [ class "friends-page" ]
        [ div [ class "friends-toolbar" ]
            [ div [ class "friends-title" ]
                [ h2 [] [ text "Friends" ]
                , small [ class "muted" ]
                    [ text
                        (String.fromInt (List.length accepted)
                            ++ " friends · "
                            ++ String.fromInt (List.length online)
                            ++ " online"
                        )
                    ]
                ]
            , nav [ class "friends-tabs", attribute "aria-label" "Friends sections" ]
                [ friendTab model.friendsTab "online" "Online" (List.length online)
                , friendTab model.friendsTab "all" "All" (List.length accepted)
                , friendTab model.friendsTab "pending" "Pending" pendingCount
                , friendTab model.friendsTab "blocked" "Blocked" (List.length blocked)
                , friendTab model.friendsTab "add" "Add Friend" 0
                ]
            ]
        , div [ class "friends-content" ]
            [ if model.friendsTab == "pending" then
                div []
                    [ friendSection "Incoming" incoming model.userStatuses
                    , friendSection "Outgoing" outgoing model.userStatuses
                    , if pendingCount == 0 then
                        friendEmpty "You're all caught up" "Incoming and outgoing requests will appear here."

                      else
                        text ""
                    ]

              else if model.friendsTab == "blocked" then
                friendList "Blocked" "Blocked people can't message you or send friend requests." blocked model.userStatuses

              else if model.friendsTab == "add" then
                addFriendPanel model

              else
                friendList listTitle
                    (if model.friendsTab == "online" then
                        "Friends who are online right now."

                     else
                        "Everyone you've added as a friend."
                    )
                    visible
                    model.userStatuses
            ]
        ]


friendTab : String -> String -> String -> Int -> Html Msg
friendTab active key label count =
    button
        [ class
            ("friends-tab"
                ++ (if active == key then
                        " active"

                    else
                        ""
                   )
            )
        , onClick (SetFriendsTab key)
        , attribute "aria-pressed"
            (if active == key then
                "true"

             else
                "false"
            )
        ]
        [ text label
        , if count > 0 then
            span [ class "tab-count" ] [ text (String.fromInt count) ]

          else
            text ""
        ]


friendList : String -> String -> List Friend -> Dict String String -> Html Msg
friendList heading description friends statuses =
    div []
        [ div [ class "friend-list-head" ]
            [ div [] [ h3 [] [ text (heading ++ "  -  " ++ String.fromInt (List.length friends)) ], p [ class "muted" ] [ text description ] ] ]
        , div [ class "card friends-list" ]
            (if List.isEmpty friends then
                [ friendEmpty
                    (if heading == "Online" then
                        "It's quiet for now"

                     else
                        "Nothing here yet"
                    )
                    (if heading == "Online" then
                        "Offline friends will still be waiting in All."

                     else
                        description
                    )
                ]

             else
                List.map (friendRow statuses) friends
            )
        ]


friendEmpty : String -> String -> Html Msg
friendEmpty title body =
    div [ class "empty friend-empty" ] [ b [] [ text title ], p [ class "muted" ] [ text body ] ]


addFriendPanel : Model -> Html Msg
addFriendPanel model =
    let
        candidates =
            model.searchUsers
                |> List.filter (\user -> Just user.id /= Maybe.map .id model.me)
    in
    div [ class "add-friend-panel" ]
        [ div [ class "add-friend-intro" ]
            [ span [ class "add-friend-icon", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-friends" ] [] ]
            , div []
                [ h3 [] [ text "Add Friend" ]
                , p [ class "muted" ] [ text "Find someone by their username or display name." ]
                ]
            ]
        , Html.form [ class "add-friend-form", onSubmit FindFriends ]
            [ span [ class "add-friend-search-icon", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-search" ] [] ]
            , input [ value model.friendQuery, onInput FriendQuery, placeholder "Search for a friend", attribute "aria-label" "Friend username", attribute "autocomplete" "off" ] []
            , button [ class "btn add-friend-submit", type_ "submit", disabled (String.length (String.trim model.friendQuery) < 2) ] [ text "Search" ]
            ]
        , if String.isEmpty (String.trim model.friendQuery) then
            div [ class "friend-discovery-hint" ]
                [ span [ class "discovery-art", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-friends" ] [] ]
                , b [] [ text "Find people you know" ]
                , p [] [ text "Search by username or display name. Partial names work too." ]
                ]

          else if List.isEmpty candidates && model.friendSearchAttempted then
            div [ class "friend-discovery-hint compact friend-not-found" ]
                [ b [] [ text "Can't find that user" ]
                , p [] [ text "Try again or check the spelling." ]
                ]

          else if List.isEmpty candidates then
            div [ class "friend-discovery-hint compact" ] [ b [] [ text "Ready to search" ], p [] [ text "Results will appear here after you press Search." ] ]

          else
            div [ class "card friends-list friend-results" ]
                (candidates |> List.map (friendCandidateRow model))
        ]


friendCandidateRow : Model -> User -> Html Msg
friendCandidateRow model user =
    let
        relationship =
            List.filter (\f -> f.user.id == user.id) model.friends |> List.head
    in
    div [ class "row friend-row" ]
        [ div [ class "clickable-user", onClick (ShowUserPopup user.id), onContextMenu (OpenUserCtx user) ] [ presenceAvatar model.userStatuses user.id user.avatarUrl user.displayName "" ]
        , div [ class "grow clickable-user", onClick (ShowUserPopup user.id) ]
            [ b [] [ text user.displayName ], small [ class "muted" ] [ text ("@" ++ user.username) ] ]
        , case relationship of
            Just f ->
                span [ class "relationship-label" ]
                    [ text
                        (if f.status == "accepted" then
                            "Already friends"

                         else if f.outgoing then
                            "Request sent"

                         else if f.incoming then
                            "Request received"

                         else
                            "Blocked"
                        )
                    ]

            Nothing ->
                button [ class "btn", onClick (BridgeEvent "friend_user" (E.int user.id)) ] [ text "Send Friend Request" ]
        ]


friendSection : String -> List Friend -> Dict String String -> Html Msg
friendSection heading friends statuses =
    if List.isEmpty friends then
        text ""

    else
        div [ class "friend-request-section" ]
            [ h3 [ class "list-section-title" ] [ text (heading ++ " · " ++ String.fromInt (List.length friends)) ]
            , div [ class "card friends-list" ] (List.map (\friend -> friendRow statuses friend) friends)
            ]


friendRow : Dict String String -> Friend -> Html Msg
friendRow userStatuses f =
    let
        statusText =
            if f.status == "accepted" then
                statusLabel userStatuses f.user.id

            else if f.incoming then
                "Incoming friend request"

            else if f.outgoing then
                "Outgoing friend request"

            else
                "Blocked"
    in
    div [ class "row friend-row" ]
        [ div [ class "clickable-user", onClick (ShowUserPopup f.user.id), onContextMenu (OpenUserCtx f.user) ]
            [ presenceAvatar userStatuses f.user.id f.user.avatarUrl f.user.displayName "" ]
        , div [ class "grow clickable-user", onClick (ShowUserPopup f.user.id) ]
            [ b [] [ text f.user.displayName ]
            , small [ class "muted" ] [ text ("@" ++ f.user.username ++ " · " ++ statusText) ]
            ]
        , div [ class "friend-actions" ]
            [ if f.incoming then
                button [ class "btn", onClick (BridgeEvent "accept_friend" (E.int f.user.id)) ] [ text "Accept" ]

              else
                text ""
            , if f.incoming then
                button [ class "btn secondary", onClick (BridgeEvent "remove_friend" (E.int f.user.id)) ] [ text "Decline" ]

              else
                text ""
            , if f.outgoing then
                button [ class "btn secondary", onClick (BridgeEvent "remove_friend" (E.int f.user.id)) ] [ text "Cancel" ]

              else
                text ""
            , if f.status == "accepted" then
                button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int f.user.id)) ] [ text "Call" ]

              else
                text ""
            , if f.status == "accepted" then
                button [ class "btn secondary", onClick (BridgeEvent "dm_user" (E.int f.user.id)) ] [ text "Message" ]

              else
                text ""
            , if f.status == "blocked" then
                button [ class "btn secondary", onClick (BridgeEvent "unblock_user" (E.int f.user.id)) ] [ text "Unblock" ]

              else
                text ""
            ]
        ]


statusLabel : Dict String String -> Int -> String
statusLabel statuses userId =
    case Dict.get (String.fromInt userId) statuses of
        Just "online" ->
            "Online"

        Just "busy" ->
            "Do Not Disturb"

        Just "away" ->
            "Idle"

        _ ->
            "Offline"


renderServerPage : Model -> Html Msg
renderServerPage model =
    case model.currentServer of
        Just data ->
            let
                canManageServer =
                    serverHasPermission 16 data.server

                canManageChannels =
                    serverHasPermission 8 data.server

                canCreateWire =
                    serverHasPermission 256 data.server

                textChannels =
                    List.filter (\c -> c.kind /= "voice") data.channels

                voiceChannels =
                    List.filter (\c -> c.kind == "voice") data.channels

                bannerClass =
                    if String.isEmpty data.server.bannerUrl then
                        "server-hero"

                    else
                        "server-hero has-banner"
            in
            div [ class "server-page page-stack", style "--server-accent" data.server.accentColor ]
                [ section
                    [ class ("card " ++ bannerClass)
                    , style "--server-accent" data.server.accentColor
                    , style "background-image"
                        (if String.isEmpty data.server.bannerUrl then
                            "none"

                         else
                            cssImage data.server.bannerUrl
                        )
                    ]
                    [ div [ class "server-hero-main" ]
                        [ serverIcon data.server
                        , div [ class "server-hero-copy" ]
                            [ span [ class "eyebrow" ] [ text "Server" ]
                            , h1 [] [ text data.server.name ]
                            , p []
                                [ text
                                    (if String.isEmpty data.server.description then
                                        "A Plainwire forum."

                                     else
                                        data.server.description
                                    )
                                ]
                            ]
                        ]
                    , div [ class "server-meta" ]
                        [ span [ class "server-meta-item" ] [ b [] [ text (String.fromInt (List.length data.members)) ], text " members" ]
                        , span [ class "server-meta-item" ] [ b [] [ text (String.fromInt (List.length textChannels)) ], text " text" ]
                        , span [ class "server-meta-item" ] [ b [] [ text (String.fromInt (List.length voiceChannels)) ], text " voice" ]
                        , span [ class "server-role-badge" ] [ text data.server.role ]
                        ]
                    , if canCreateWire || canManageChannels || canManageServer then
                        div [ class "server-hero-actions" ]
                            ([ if canCreateWire then
                                    button [ class "btn", onClick (InviteModal data.server.id) ] [ text "Create Wire" ]

                               else
                                    text ""
                             , if canManageChannels then
                                    button [ class "btn secondary", onClick (ChannelModal data.server.id) ] [ text "Add channel" ]

                               else
                                    text ""
                             , if canManageServer then
                                    button [ class "btn secondary", onClick (EditServerModal data.server) ] [ text "Customize" ]

                               else
                                    text ""
                             ]
                            )

                      else
                        text ""
                    ]
                , if String.isEmpty data.server.welcomeMessage then
                    text ""

                  else
                    section [ class "card server-welcome" ]
                        [ h2 [] [ text "Welcome" ]
                        , Html.node "pw-markdown" [ attribute "source" data.server.welcomeMessage ] []
                        ]
                , div [ class "server-overview-grid" ]
                    [ section [ class "card server-overview-panel server-channel-panel" ]
                        [ div [ class "section-head compact-section-head" ]
                            [ div []
                                [ h2 [] [ text "Channels" ]
                                , p [ class "muted" ] [ text "Jump into text or voice." ]
                                ]
                            , if canManageChannels then
                                button [ class "btn ghost", onClick (ChannelModal data.server.id) ] [ text "Add" ]

                              else
                                text ""
                            ]
                        , div [ class "server-channel-card" ]
                            (channelGroup model "Text channels" textChannels
                                ++ channelGroup model "Voice channels" voiceChannels
                            )
                        ]
                    , section [ class "card server-overview-panel server-member-panel" ]
                        [ div [ class "section-head compact-section-head" ]
                            [ div []
                                [ h2 [] [ text "Members" ]
                                , p [ class "muted" ] [ text (String.fromInt (List.length data.members) ++ " people in this server") ]
                                ]
                            ]
                        , div [ class "server-member-list" ] (List.map (\m -> memberRow model.userStatuses data.server.id m) data.members)
                        ]
                    ]
                ]

        Nothing ->
            div [ class "page-loading" ] [ span [ class "loading-dot" ] [], text "Loading server" ]


channelRow : Model -> Channel -> Html Msg
channelRow model c =
    let
        target =
            if c.kind == "voice" then
                "#voice/"

            else
                "#channel/"

        mentions =
            channelNotificationCount model c.id
    in
    a [ class "row channel-link", href (target ++ String.fromInt c.id), onClick (Go (target ++ String.fromInt c.id)), onContextMenu (OpenChannelCtx c) ]
        [ span
            [ class
                ("channel-glyph "
                    ++ (if c.kind == "voice" then
                            "voice"

                        else
                            "text"
                       )
                )
            , attribute "aria-hidden" "true"
            ]
            []
        , div [ class "grow" ]
            [ b [] [ text c.name ]
            , if mentions == 0 && c.kind == "text" && Set.member ("channel:" ++ String.fromInt c.id) model.mentionHints then
                span [ class "pill mention-chip" ] [ text "mentioned" ]

              else
                text ""
            , small [ class "muted" ]
                [ text
                    (if c.kind == "voice" then
                        "Voice channel"

                     else
                        "Text channel"
                    )
                ]
            ]
        , notificationBadge mentions
        ]


managedChannelRow : Model -> Bool -> List Category -> Channel -> Html Msg
managedChannelRow model canManage categories channel =
    let
        target =
            if channel.kind == "voice" then
                "#voice/"

            else
                "#channel/"

        selectedCategory =
            Maybe.map String.fromInt channel.categoryId |> Maybe.withDefault ""

        moveTarget raw =
            MoveChannelToCategory channel.id
                (if String.isEmpty raw then
                    Nothing

                 else
                    String.toInt raw
                )

        categoryOptions =
            option [ value "" ] [ text "No category" ]
                :: List.map (\category -> option [ value (String.fromInt category.id) ] [ text category.name ]) categories

        mentions =
            channelNotificationCount model channel.id
    in
    div [ class "row", onClick (Go (target ++ String.fromInt channel.id)), onContextMenu (OpenChannelCtx channel) ]
        [ span
            [ class
                ("channel-glyph "
                    ++ (if channel.kind == "voice" then
                            "voice"

                        else
                            "text"
                       )
                )
            , attribute "aria-hidden" "true"
            ]
            []
        , div [ class "grow" ]
            [ b [] [ text channel.name ]
            , if mentions == 0 && channel.kind == "text" && Set.member ("channel:" ++ String.fromInt channel.id) model.mentionHints then
                span [ class "pill mention-chip" ] [ text "mentioned" ]

              else
                text ""
            , small [ class "muted" ]
                [ text
                    (if channel.kind == "voice" then
                        "Voice channel"

                     else
                        "Text channel"
                    )
                ]
            ]
        , notificationBadge (channelNotificationCount model channel.id)
        , if canManage then
            select
                [ class "channel-category-select"
                , value selectedCategory
                , title "Move channel to category"
                , attribute "aria-label" ("Move " ++ channel.name ++ " to category")
                , stopClick
                , onInput moveTarget
                ]
                categoryOptions

          else
            text ""
        ]


memberRow : Dict String String -> Int -> ServerMember -> Html Msg
memberRow userStatuses serverId m =
    let
        displayName =
            if String.isEmpty (String.trim m.nickname) then
                m.user.displayName
            else
                m.nickname

        avatarUrl =
            if String.isEmpty (String.trim m.serverAvatarUrl) then
                m.user.avatarUrl
            else
                m.serverAvatarUrl

        roleText =
            if String.isEmpty (String.trim m.roleNames) then
                m.role
            else
                m.roleNames

        roleAttrs =
            if String.isEmpty m.roleColor then
                [ class "server-member-role" ]
            else
                [ class "server-member-role", style "color" m.roleColor ]
    in
    div
        [ class "row member-row clickable-user"
        , onClick (ShowServerProfile serverId m.user.id)
        , onContextMenu (OpenServerMemberCtx serverId m)
        , attribute "data-long-context" "true"
        , title (if String.isEmpty m.serverBio then displayName else m.serverBio)
        ]
        [ presenceAvatar userStatuses m.user.id avatarUrl displayName ""
        , div [ class "grow" ]
            [ b
                (if String.isEmpty m.roleColor then
                    []

                 else
                    [ style "color" m.roleColor ]
                )
                [ text displayName ]
            , botBadge m.user.isBot
            , small [ class "muted" ] [ text ("@" ++ m.user.username ++ " · "), span roleAttrs [ text roleText ] ]
            ]
        ]


renderVoicePage : Int -> Model -> Html Msg
renderVoicePage channelId model =
    let
        joined =
            model.voice.mode == Just "voice" && model.voice.id == Just channelId

        members =
            Maybe.map .members model.currentServer |> Maybe.withDefault []

        voiceUsers =
            Dict.values model.voice.users

        hasScreenShare =
            List.any .screen voiceUsers

        shareCount =
            List.length (List.filter .screen voiceUsers)

        audioShareCount =
            List.length (List.filter (\user -> user.screen && user.screenAudio) voiceUsers)

        participantCount =
            List.length (List.filter (\user -> not user.reconnecting) voiceUsers)

        reconnectingCount =
            List.length voiceUsers - participantCount

        participantCountText =
            String.fromInt participantCount
                ++ " in call"
                ++ (if reconnectingCount > 0 then
                        " · " ++ String.fromInt reconnectingCount ++ " reconnecting"

                    else
                        ""
                   )
    in
    div []
        [ div [ class "card pad voice-card" ]
            [ div [ class "voice-header" ]
                [ h2 [] [ text "Voice channel" ]
                , if joined then
                    span [ class "voice-count" ] [ text participantCountText ]

                  else
                    text ""
                ]
            , p [ class "muted" ] [ text "Join when you want to talk. Use Enable audio if your phone or browser blocks playback." ]
            , div [ class "voice-actions" ]
                [ if joined then
                    button [ class "btn call-decline", onClick EndCall ] [ text "Leave" ]

                  else
                    button [ class "btn primary-join", onClick (BridgeEvent "join_voice" (E.int channelId)) ] [ text "Join" ]
                , button
                    [ class
                        ("btn"
                            ++ (if model.voice.muted then
                                    " call-muted"

                                else
                                    " secondary"
                               )
                        )
                    , attribute "aria-pressed"
                        (if model.voice.muted then
                            "true"

                         else
                            "false"
                        )
                    , onClick (BridgeEvent "toggle_mute" E.null)
                    ]
                    [ text
                        (if model.voice.muted then
                            "Unmute"

                         else
                            "Mute"
                        )
                    ]
                , button
                    [ class
                        ("btn"
                            ++ (if model.voice.deafened then
                                    " call-muted"

                                else
                                    " secondary"
                               )
                        )
                    , attribute "aria-pressed"
                        (if model.voice.deafened then
                            "true"

                         else
                            "false"
                        )
                    , onClick (BridgeEvent "toggle_deafen" E.null)
                    ]
                    [ text
                        (if model.voice.deafened then
                            "Undeafen"

                         else
                            "Deafen"
                        )
                    ]
                , button [ class "btn secondary", onClick (BridgeEvent "unlock_audio" E.null) ] [ text "Enable audio" ]
                , if joined then
                    if model.voice.screenShare then
                        button [ class "btn call-decline share-active", onClick StopScreenShare ] [ text "Stop share" ]

                    else
                        button [ class "btn share-btn", onClick StartScreenShare ] [ text "Share screen" ]

                  else
                    text ""
                ]
            , if hasScreenShare then
                div [ class "voice-screen-banner" ]
                    [ span [ class "screen-pulse" ] []
                    , text
                        (String.fromInt shareCount
                            ++ " sharing"
                            ++ (if audioShareCount > 0 then
                                    " · audio included"

                                else
                                    ""
                               )
                            ++ " · Choose Watch screen below"
                        )
                    ]

              else
                text ""
            , div [ class "voice-participants" ]
                (if not joined || List.isEmpty voiceUsers then
                    [ div [ class "empty voice-empty" ]
                        [ text
                            (if joined then
                                "Waiting for others to join..."

                             else
                                "Join to see voice participants."
                            )
                        ]
                    ]

                 else
                    List.map (voiceParticipantRow (Maybe.map .id model.me) members) voiceUsers
                )
            ]
        ]


voiceParticipantRow : Maybe Int -> List ServerMember -> VoiceUser -> Html Msg
voiceParticipantRow selfId members vu =
    let
        maybeMember =
            List.filter (\m -> m.user.id == vu.userId) members |> List.head

        rosterFallbackName =
            if String.isEmpty (String.trim vu.displayName) then
                "User " ++ String.fromInt vu.userId

            else
                vu.displayName

        name =
            maybeMember
                |> Maybe.map
                    (\m ->
                        if String.isEmpty (String.trim m.nickname) then
                            m.user.displayName

                        else
                            m.nickname
                    )
                |> Maybe.withDefault rosterFallbackName

        avatarUrl =
            maybeMember
                |> Maybe.map
                    (\m ->
                        if String.isEmpty (String.trim m.serverAvatarUrl) then
                            m.user.avatarUrl

                        else
                            m.serverAvatarUrl
                    )
                |> Maybe.withDefault vu.avatarUrl

        stateText =
            if vu.reconnecting then
                "Reconnecting"

            else if vu.screen && vu.screenAudio then
                "Sharing screen with audio"

            else if vu.screen then
                "Sharing screen"

            else if vu.deafened then
                "Deafened"

            else if vu.muted then
                "Muted"

            else
                "Live"

        pillClass =
            if vu.reconnecting then
                "voice-state-pill reconnecting"

            else if vu.screen then
                "voice-state-pill sharing"

            else if vu.muted || vu.deafened then
                "voice-state-pill muted"

            else
                "voice-state-pill live"

        pillText =
            if vu.reconnecting then
                "Rejoining"

            else if vu.screen && vu.screenAudio then
                "Sharing + audio"

            else if vu.screen then
                "Sharing"

            else if vu.deafened then
                "Deafened"

            else if vu.muted then
                "Muted"

            else
                "Live"
    in
    div
        [ class
            ("row voice-participant"
                ++ (if vu.screen then
                        " screen-sharing"

                    else
                        ""
                   )
            )
        ]
        [ avatarImg avatarUrl name "small"
        , div [ class "grow" ]
            [ b [] [ text name ]
            , small [ class "muted" ] [ text stateText ]
            ]
        , if vu.screen then
            button
                [ class "btn secondary watch-screen"
                , title
                    (if vu.screenAudio then
                        "Watch screen; shared audio is included"

                     else
                        "Watch screen"
                    )
                , onClick (BridgeEvent "watch_screen" (E.int vu.userId))
                ]
                [ text "Watch screen" ]

          else
            span [ class pillClass ] [ text pillText ]
        , if selfId == Just vu.userId then
            Html.node "pw-input-volume" [] []

          else
            Html.node "pw-user-volume" [ attribute "user-id" (String.fromInt vu.userId), attribute "user-name" name ] []
        ]


renderProfilePage : Model -> Html Msg
renderProfilePage model =
    case model.currentProfile of
        Just u ->
            let
                viewingSelf =
                    Maybe.map .id model.me == Just u.id

                liveStatus =
                    Dict.get (String.fromInt u.id) model.userStatuses

                presence =
                    Maybe.withDefault "offline" liveStatus

                activityText =
                    case liveStatus of
                        Just "away" ->
                            "Away"

                        Just "busy" ->
                            "Do not disturb"

                        Just "invisible" ->
                            "Offline"

                        Just _ ->
                            "Online"

                        Nothing ->
                            let
                                elapsed =
                                    agoAt model.serverTime u.lastSeen
                            in
                            if elapsed == "never" then
                                "Offline"

                            else if elapsed == "now" || elapsed == "1s" then
                                "Last seen just now"

                            else
                                "Last seen " ++ elapsed ++ " ago"
            in
            article [ class "card profile profile-page-card" ]
                [ div
                    [ class
                        ("banner profile-cover"
                            ++ (if String.isEmpty u.bannerUrl then
                                    " empty"

                                else
                                    ""
                               )
                        )
                    , style "background-image"
                        (if String.isEmpty u.bannerUrl then
                            "none"

                         else
                            cssImage u.bannerUrl
                        )
                    ]
                    []
                , div [ class "profile-body profile-layout" ]
                    [ div [ class "profile-avatar-column" ]
                        [ presenceAvatar model.userStatuses u.id u.avatarUrl u.displayName "big" ]
                    , div [ class "profile-copy" ]
                        [ div [ class "profile-title-row" ]
                            [ div []
                                [ div [ class "profile-name-line" ] [ h1 [] [ text u.displayName ], botBadge u.isBot ]
                                , p [ class "muted profile-identity" ] [ text ("@" ++ u.username) ]
                                ]
                            , span [ class ("presence-pill profile-presence " ++ presence) ]
                                [ span [ class ("status-dot " ++ presence) ] [], text activityText ]
                            ]
                        , div [ class "profile-bio" ]
                            [ span [ class "profile-section-label" ] [ text "About" ]
                            , p []
                                [ text
                                    (if String.isEmpty (String.trim u.bio) then
                                        "No bio set yet."

                                     else
                                        u.bio
                                    )
                                ]
                            ]
                        , div [ class "profile-actions" ]
                            [ if viewingSelf then
                                button [ class "btn", onClick (Go "#settings") ] [ text "Edit profile" ]

                              else
                                text ""
                            , if not viewingSelf && model.currentProfileRelationship /= "blocked" then
                                button [ class "btn", onClick (BridgeEvent "dm_user" (E.int u.id)) ] [ text "Message" ]

                              else
                                text ""
                            , if not viewingSelf && model.currentProfileRelationship /= "blocked" then
                                button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int u.id)) ] [ text "Call" ]

                              else
                                text ""
                            , if not viewingSelf && model.currentProfileRelationship == "blocked" && model.currentProfileBlockedByMe then
                                button [ class "btn danger", onClick (BridgeEvent "unblock_user" (E.int u.id)) ] [ text "Unblock" ]

                              else if not viewingSelf && model.currentProfileRelationship == "blocked" then
                                button [ class "btn secondary", disabled True ] [ text "Unavailable" ]

                              else if not viewingSelf then
                                button [ class "btn ghost profile-more-action", onClick (BridgeEvent "block_user" (E.int u.id)) ] [ text "Block" ]

                              else
                                text ""
                            ]
                        ]
                    ]
                ]

        Nothing ->
            div [ class "page-loading" ] [ span [ class "loading-dot" ] [], text "Loading profile" ]


renderNewServerPage : Model -> Html Msg
renderNewServerPage model =
    div [ class "server-create-page" ]
        [ section [ class "server-create-intro" ]
            [ span [ class "server-create-mark" ] [ text "+" ]
            , span [ class "eyebrow" ] [ text "New space" ]
            , h1 [] [ text "Create a server" ]
            , p [ class "muted" ] [ text "Give your group a home. Plainwire creates sensible text and voice defaults, and you can customize everything afterward." ]
            , div [ class "server-create-preview" ]
                [ div [ class "server-icon" ]
                    [ text
                        (if String.isEmpty (String.trim model.serverName) then
                            "S"

                         else
                            String.left 1 (String.toUpper model.serverName)
                        )
                    ]
                , div []
                    [ b []
                        [ text
                            (if String.isEmpty (String.trim model.serverName) then
                                "Your server"

                             else
                                String.trim model.serverName
                            )
                        ]
                    , small [ class "muted" ]
                        [ text
                            (if String.isEmpty (String.trim model.serverDescription) then
                                "A place for your friends"

                             else
                                String.trim model.serverDescription
                            )
                        ]
                    ]
                ]
            ]
        , section [ class "card server-create-form" ]
            [ div [ class "field" ] [ label [] [ text "Server name" ], input [ value model.serverName, maxlength 80, placeholder "Weekend crew", onInput ServerName ] [] ]
            , div [ class "field" ] [ label [] [ text "What is it for?" ], textarea [ value model.serverDescription, maxlength 280, placeholder "Games, projects, hanging out…", onInput ServerDescription ] [] ]
            , div [ class "server-create-defaults" ]
                [ div [] [ span [ class "server-default-icon" ] [ text "T" ], span [] [ b [] [ text "general" ], small [ class "muted" ] [ text "Text channel" ] ] ]
                , div [] [ span [ class "server-default-icon" ] [ text "V" ], span [] [ b [] [ text "Lounge" ], small [ class "muted" ] [ text "Voice ready" ] ] ]
                ]
            , div [ class "modal-actions server-create-actions" ]
                [ button [ class "btn secondary", onClick (Go "#") ] [ text "Cancel" ]
                , button [ class "btn", disabled (String.length (String.trim model.serverName) < 2), onClick (CreateServer model.serverName model.serverDescription) ] [ text "Create server" ]
                ]
            ]
        ]


renderInvitePage : Model -> Html Msg
renderInvitePage model =
    case model.invitePreview of
        Just invite ->
            div [ class "card pad invite-card" ]
                [ div [ class "server-icon" ] [ text (String.left 1 (String.toUpper invite.serverName)) ]
                , h1 [] [ text invite.serverName ]
                , p [ class "muted" ] [ text invite.serverDescription ]
                , p [ class "muted" ] [ text (String.fromInt invite.memberCount ++ " members") ]
                , if invite.valid then
                    button [ class "btn", onClick JoinInvite ] [ text "Join server" ]

                  else
                    p [ class "muted" ] [ text "This Wire is no longer valid." ]
                , button [ class "btn secondary", onClick (Go "#") ] [ text "Back home" ]
                ]

        Nothing ->
            div [ class "empty" ] [ text "Loading Wire..." ]


renderMessagePage : String -> String -> Model -> Html Msg
renderMessagePage draftKey placeholderText model =
    let
        callBar =
            case model.active of
                DmView convId ->
                    case callForConversation convId model of
                        Just active ->
                            [ renderDmCallBar active model ]

                        Nothing ->
                            []

                _ ->
                    []

        chatSurface =
            div
                ([ class "chat-surface" ]
                    ++ (case ( model.active, model.currentServer ) of
                            ( ChannelView _, Just data ) ->
                                [ style "--server-accent" data.server.accentColor ]

                            _ ->
                                []
                       )
                )
                (callBar
                    ++ [ renderChatHeader model
                       , Keyed.node "div"
                            [ class "messages", id "messages", attribute "aria-label" "Messages" ]
                            ([ ( "history"
                               , div [ id "message-history-sentinel", class "message-history-sentinel", attribute "aria-hidden" "true" ]
                                    [ if model.loadingOlderMessages then
                                        text "Loading older messages…"

                                      else
                                        text ""
                                    ]
                               )
                             ]
                                ++ (if List.isEmpty model.msg then
                                        [ ( "empty", div [ class "empty chat-empty" ] [ div [ class "chat-empty-mark", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-messages" ] [] ], h2 [] [ text "Start the conversation" ], p [ class "muted" ] [ text "Send a message, share a file, or make a call." ] ] ) ]

                                    else
                                        groupedMessageViews model model.msg
                                   )
                            )
                       , Html.node "pw-scroll-tools" [] []
                       , Composer.view draftKey placeholderText model
                       ]
                )

        groupMembers =
            case model.active of
                DmView conversationId ->
                    model.convs
                        |> List.filter (\conversation -> conversation.id == conversationId && conversation.memberCount > 2)
                        |> List.head
                        |> Maybe.map
                            (\conversation ->
                                let
                                    cachedMembers =
                                        Dict.get conversationId model.conversationMembers |> Maybe.withDefault conversation.members
                                in
                                renderGroupMembers model { conversation | members = cachedMembers }
                            )

                _ ->
                    Nothing
    in
    case groupMembers of
        Just members ->
            div [ class "chat-with-members" ] [ chatSurface, members ]

        Nothing ->
            chatSurface


renderPeoplePicker : Maybe Int -> Model -> Html Msg
renderPeoplePicker conversationId model =
    let
        conversation =
            model.convs |> List.filter (\c -> Just c.id == conversationId) |> List.head

        existing =
            conversation
                |> Maybe.map (\c -> Dict.get c.id model.conversationMembers |> Maybe.withDefault c.members)
                |> Maybe.withDefault []
                |> List.map (.user >> .id)

        excluded =
            (Maybe.map .id model.me |> Maybe.withDefault 0) :: existing ++ (model.friends |> List.filter .blockedByMe |> List.map (.user >> .id))

        selected =
            csvUsernames model.modalUserIds

        limit =
            conversation |> Maybe.map (\c -> Basics.max 0 (50 - c.memberCount)) |> Maybe.withDefault 49

        contacts =
            (List.map .user (List.filter (\f -> f.status == "accepted" && not f.blockedByMe) model.friends)
                ++ List.concatMap (.members >> List.map .user) model.convs
                ++ (model.currentServer |> Maybe.map (.members >> List.map .user) |> Maybe.withDefault [])
            )
                |> List.filter (\u -> not (List.member u.id excluded))
                |> List.map (\u -> ( u.id, u ))
                |> Dict.fromList
                |> Dict.values
                |> List.sortBy (.displayName >> String.toLower)

        query =
            String.toLower (String.trim model.modalPeopleQuery)

        matches =
            contacts |> List.filter (\u -> String.contains query (String.toLower (u.displayName ++ " " ++ u.username)))

        remove username =
            ModalUserIds (String.join ", " (List.filter ((/=) username) selected))

        person user =
            let
                username =
                    normalizeUsernameInput user.username

                chosen =
                    List.member username selected
            in
            button
                [ class
                    ("people-option"
                        ++ (if chosen then
                                " selected"

                            else
                                ""
                           )
                    )
                , type_ "button"
                , attribute "aria-pressed"
                    (if chosen then
                        "true"

                     else
                        "false"
                    )
                , attribute "aria-label" ("Select " ++ user.displayName)
                , disabled (not chosen && List.length selected >= limit)
                , onClick
                    (if chosen then
                        remove username

                     else
                        ModalUserIds (String.join ", " (selected ++ [ username ]))
                    )
                ]
                [ presenceAvatar model.userStatuses user.id user.avatarUrl user.displayName ""
                , div [ class "people-option-copy" ] [ b [] [ text user.displayName ], small [] [ text ("@" ++ user.username) ] ]
                , span [ class "people-check", attribute "aria-hidden" "true" ]
                    [ text
                        (if chosen then
                            "✓"

                         else
                            "+"
                        )
                    ]
                ]
    in
    div [ class "people-picker" ]
        [ div [ class "people-selection-head" ] [ b [] [ text "People" ], small [ attribute "aria-live" "polite" ] [ text (String.fromInt (List.length selected) ++ " / " ++ String.fromInt limit ++ " selected") ] ]
        , div [ class "people-selected" ]
            (List.map (\username -> button [ class "person-chip", type_ "button", onClick (remove username), attribute "aria-label" ("Remove " ++ username) ] [ text ("@" ++ username), span [ attribute "aria-hidden" "true" ] [ text "×" ] ]) selected)
        , input [ class "people-search", type_ "search", value model.modalPeopleQuery, placeholder "Find a friend or someone you know", attribute "aria-label" "Find people to add", onInput (SetModalChoice "people_query"), attribute "autocomplete" "off" ] []
        , div [ class "people-options", attribute "aria-label" "People you know" ]
            (if List.isEmpty matches then
                [ p [ class "people-empty muted" ] [ text "No matches. You can add someone by username below." ] ]

             else
                List.map person matches
            )
        , details [ class "people-manual" ]
            [ summary [] [ text "Add by username" ]
            , div [ class "field" ] [ label [ attribute "for" "people-usernames" ] [ text "Selected usernames" ], input [ id "people-usernames", value model.modalUserIds, maxlength 1600, placeholder "alice, bob", onInput ModalUserIds, attribute "autocomplete" "off" ] [], small [ class "muted" ] [ text "Use commas to separate names. Everyone selected above is included here." ] ]
            ]
        ]


renderServerIdentityPreview : Model -> Html Msg
renderServerIdentityPreview model =
    div [ class "server-identity-preview", style "--server-accent" model.modalAccentColor ]
        [ div [ class "server-preview-banner" ]
            [ if String.isEmpty model.modalBannerUrl then
                text ""

              else
                img [ src model.modalBannerUrl, alt "Server banner preview", attribute "referrerpolicy" "no-referrer" ] []
            ]
        , div [ class "server-preview-identity" ]
            [ div [ class "server-preview-icon" ]
                [ if String.isEmpty model.modalUserIds then
                    text (String.toUpper (String.left 1 model.modalTitle))

                  else
                    img [ src model.modalUserIds, alt "Server icon preview", attribute "referrerpolicy" "no-referrer" ] []
                ]
            , div []
                [ span [ class "eyebrow" ] [ text "Server preview" ]
                , h3 []
                    [ text
                        (if String.isEmpty model.modalTitle then
                            "Your server"

                         else
                            model.modalTitle
                        )
                    ]
                , p [ class "muted" ] [ text model.modalBody ]
                ]
            ]
        , div [ class "server-preview-channels" ]
            [ div [ class "server-preview-channel active" ] [ span [] [ text "#" ], text " general" ]
            , div [ class "server-preview-channel" ] [ span [] [ text "♪" ], text " lounge" ]
            ]
        ]


renderGroupMembers : Model -> Conversation -> Html Msg
renderGroupMembers model conversation =
    aside [ class "group-members", attribute "aria-label" "Group members" ]
        [ div [ class "group-members-head" ]
            [ div []
                [ span [ class "eyebrow" ] [ text "People" ]
                , h3 [] [ text (String.fromInt conversation.memberCount ++ " members") ]
                ]
            , button [ class "btn ghost group-manage-btn", type_ "button", onClick (BridgeEvent "open_group_admin" (E.int conversation.id)) ]
                [ text
                    (if conversation.groupRole == "owner" || conversation.groupRole == "moderator" then
                        "Manage"

                     else
                        "Members"
                    )
                ]
            ]
        , div [ class "group-members-list" ]
            (if List.isEmpty conversation.members then
                [ div [ class "group-members-loading" ]
                    [ p [ class "muted" ] [ text "Members could not be loaded." ]
                    , button [ class "btn secondary", onClick (SetRoute ("#dm/" ++ String.fromInt conversation.id)) ] [ text "Retry" ]
                    ]
                ]

             else
                List.map (groupMemberRow model conversation.ownerId) conversation.members
            )
        ]


groupMemberRow : Model -> Int -> MemberUser -> Html Msg
groupMemberRow model ownerId member =
    let
        user =
            member.user
    in
    button [ class "group-member", onClick (ShowUserPopup user.id), onContextMenu (OpenUserCtx user), attribute "aria-label" ("Open " ++ user.displayName ++ "'s profile") ]
        [ div [ class "group-member-avatar" ]
            [ presenceAvatar model.userStatuses user.id user.avatarUrl user.displayName ""
            ]
        , div [ class "group-member-copy" ]
            [ b [] [ text user.displayName ]
            , small [ class "muted" ] [ text ("@" ++ user.username) ]
            ]
        , if user.id == ownerId || member.role == "owner" then
            span [ class "pill group-owner" ] [ text "owner" ]

          else if member.role == "moderator" then
            span [ class "pill group-moderator" ] [ text "mod" ]

          else
            text ""
        ]


renderChatHeader : Model -> Html Msg
renderChatHeader model =
    case model.active of
        DmView id ->
            case List.filter (\c -> c.id == id) model.convs of
                c :: _ ->
                    let
                        activeCall =
                            callForConversation id model

                        hasCall =
                            activeCall /= Nothing

                        joinedCall =
                            isJoinedCall id model
                    in
                    div [ class "chat-header" ]
                        [ button [ class "chat-mobile-menu", type_ "button", onClick ToggleSidebar, attribute "aria-label" "Open navigation" ] [ span [ class "ui-icon ui-icon-menu", attribute "aria-hidden" "true" ] [] ]
                        , convAvatar model c
                        , div [ class "grow" ]
                            [ h2 [] [ text (convName c) ]
                            , small [ class "muted" ]
                                [ text
                                    (if c.memberCount > 2 then
                                        String.fromInt c.memberCount ++ " people"

                                     else
                                        "Direct message"
                                    )
                                ]
                            ]
                        , if c.memberCount > 2 && (c.groupRole == "owner" || c.groupRole == "moderator") then
                            button [ class "btn secondary group-add-button", type_ "button", onClick (AddPeopleModal id), attribute "aria-label" "Add people to group", title "Add people to group" ] [ span [ class "ui-icon ui-icon-friends", attribute "aria-hidden" "true" ] [], span [ class "group-add-label" ] [ text "Add people" ] ]

                          else
                            text ""
                        , if model.messageContextMode then
                            button [ class "btn secondary chat-history-action", type_ "button", onClick ReturnToLatestMessages, title "Return to the newest messages" ] [ text "Latest" ]

                          else
                            text ""
                        , chatConnectionBadge model
                        , if joinedCall then
                            button [ class "btn call-decline chat-call-action", onClick EndCall ] [ span [ class "ui-icon ui-icon-call-end", attribute "aria-hidden" "true" ] [], span [ class "chat-call-label" ] [ text "Leave" ] ]

                          else if hasCall then
                            button [ class "btn call-accept chat-call-action", onClick (JoinCall id) ]
                                [ span [ class "ui-icon ui-icon-call", attribute "aria-hidden" "true" ] []
                                , span [ class "chat-call-label" ] [ text (activeCall |> Maybe.map (\active -> callJoinShortLabel active model) |> Maybe.withDefault "Join") ]
                                ]

                          else
                            button [ class "btn chat-call-action", onClick (BridgeEvent "start_call" (E.int id)), attribute "aria-label" "Start call" ] [ span [ class "ui-icon ui-icon-call", attribute "aria-hidden" "true" ] [], span [ class "chat-call-label" ] [ text "Call" ] ]
                        ]

                [] ->
                    chatOnlineHeader model

        ChannelView channelId ->
            channelChatHeader channelId model

        _ ->
            chatOnlineHeader model


isJoinedCall : Int -> Model -> Bool
isJoinedCall conversationId model =
    model.voice.mode == Just "call" && model.voice.id == Just conversationId


callForConversation : Int -> Model -> Maybe ActiveCall
callForConversation conversationId model =
    if isJoinedCall conversationId model then
        Maybe.andThen
            (\call ->
                if call.conversationId == conversationId then
                    Just call

                else
                    Nothing
            )
            model.callUI.active

    else
        Dict.get conversationId model.activeCalls


callJoinLabel : ActiveCall -> Model -> String
callJoinLabel active model =
    case Maybe.map .id model.me of
        Nothing ->
            "Join Call"

        Just myId ->
            case List.filter (\user -> user.userId == myId) active.users |> List.head of
                Just user ->
                    if user.reconnecting then
                        "Rejoin Call"

                    else
                        "Take Over Call"

                Nothing ->
                    "Join Call"


callJoinShortLabel : ActiveCall -> Model -> String
callJoinShortLabel active model =
    case callJoinLabel active model of
        "Rejoin Call" ->
            "Rejoin"

        "Take Over Call" ->
            "Take over"

        _ ->
            "Join"


renderDmCallBar : ActiveCall -> Model -> Html Msg
renderDmCallBar active model =
    let
        connectedCount =
            List.length (List.filter (\user -> not user.reconnecting) active.users)

        reconnectingCount =
            List.length active.users - connectedCount

        joinedCall =
            isJoinedCall active.conversationId model

        selfPresence =
            model.me
                |> Maybe.andThen
                    (\me ->
                        active.users
                            |> List.filter (\user -> user.userId == me.id)
                            |> List.head
                    )

        remoteSeatStatus =
            if joinedCall then
                ""

            else
                case selfPresence of
                    Just user ->
                        if user.reconnecting then
                            " · Your previous session is reconnecting"

                        else
                            " · You are connected elsewhere"

                    Nothing ->
                        ""

        countText =
            let
                connectedText =
                    if connectedCount == 0 then
                        "No one connected"

                    else
                        String.fromInt connectedCount
                            ++ " participant"
                            ++ (if connectedCount /= 1 then
                                    "s"

                                else
                                    ""
                               )
            in
            (if reconnectingCount > 0 then
                connectedText
                    ++ " · "
                    ++ String.fromInt reconnectingCount
                    ++ " reconnecting"

             else
                connectedText
            )
                ++ remoteSeatStatus
    in
    div [ class "dm-call-bar" ]
        [ div [ class "dm-call-bar-main" ]
            [ span [ class "dm-call-bar-icon" ] [ callIcon "audio" ]
            , span [ class "dm-call-bar-title" ]
                [ text
                    (if joinedCall then
                        "In call"

                     else
                        "Call active"
                    )
                ]
            , if joinedCall then
                liveCallTimer "dm-call-bar-timer pw-live-call-timer" active.startTime

              else
                span [ class "dm-call-bar-timer" ]
                    [ text
                        (case selfPresence of
                            Just user ->
                                if user.reconnecting then
                                    "Ready to rejoin"

                                else
                                    "Connected elsewhere"

                            Nothing ->
                                "Ready to join"
                        )
                    ]
            , span [ class "dm-call-bar-count" ] [ text countText ]
            ]
        , div [ class "dm-call-bar-controls" ]
            (if joinedCall then
                [ button [ class "btn secondary", onClick ToggleCallOverlay ]
                    [ text
                        (if active.expanded then
                            "Minimize"

                         else
                            "Call details"
                        )
                    ]
                ]

             else
                [ button [ class "btn call-accept", onClick (JoinCall active.conversationId) ] [ text (callJoinLabel active model) ] ]
            )
        ]


channelChatHeader : Int -> Model -> Html Msg
channelChatHeader channelId model =
    let
        channel =
            model.currentServer
                |> Maybe.andThen (\data -> data.channels |> List.filter (\item -> item.id == channelId) |> List.head)

        channelName =
            channel |> Maybe.map .name |> Maybe.withDefault "Channel"

        channelTopic =
            channel |> Maybe.map .topic |> Maybe.withDefault ""

        slowmodeSeconds =
            channel |> Maybe.map .slowmodeSeconds |> Maybe.withDefault 0

        channelMeta =
            let
                base =
                    if String.isEmpty (String.trim channelTopic) then
                        "Text channel"

                    else
                        channelTopic
            in
            if slowmodeSeconds > 0 then
                base ++ " · Slowmode " ++ String.fromInt slowmodeSeconds ++ "s"

            else
                base
    in
    div [ class "chat-header channel-chat-header" ]
        [ button [ class "chat-mobile-menu", type_ "button", onClick ToggleSidebar, attribute "aria-label" "Open navigation" ] [ span [ class "ui-icon ui-icon-menu", attribute "aria-hidden" "true" ] [] ]
        , span [ class "channel-header-mark", attribute "aria-hidden" "true" ] [ text "#" ]
        , div [ class "grow" ]
            [ h2 [] [ text channelName ]
            , small [ class "muted" ] [ text channelMeta ]
            ]
        , if model.messageContextMode then
            button [ class "btn secondary chat-history-action", type_ "button", onClick ReturnToLatestMessages, title "Return to the newest messages" ] [ text "Latest" ]

          else
            text ""
        , button
            [ class "btn secondary chat-history-action"
            , type_ "button"
            , onClick (OpenPinnedMessages channelId)
            , title "Pinned messages"
            , attribute "aria-label" "Open pinned messages"
            ]
            [ span [ class "channel-pin-symbol", attribute "aria-hidden" "true" ] [ text "📌" ]
            , span [ class "chat-history-label" ] [ text "Pins" ]
            ]
        , chatConnectionBadge model
        ]


chatConnectionBadge : Model -> Html Msg
chatConnectionBadge model =
    if model.wsConnected then
        text ""

    else
        span [ class "chat-connection-badge", attribute "role" "status" ]
            [ span [ class "chat-connection-dot", attribute "aria-hidden" "true" ] []
            , text "Reconnecting"
            ]


chatOnlineHeader : Model -> Html Msg
chatOnlineHeader model =
    div [ class "chat-status" ]
        [ button [ class "chat-mobile-menu", type_ "button", onClick ToggleSidebar, attribute "aria-label" "Open navigation" ] [ span [ class "ui-icon ui-icon-menu", attribute "aria-hidden" "true" ] [] ]
        , span [ class "live-dot" ] []
        , span []
            [ text
                (if model.wsConnected then
                    "Online"

                 else
                    "Reconnecting"
                )
            ]
        ]


draftKeyFor : ActiveRoute -> String
draftKeyFor route =
    case route of
        DmView id ->
            "direct:" ++ String.fromInt id

        ChannelView id ->
            "channel:" ++ String.fromInt id

        ThreadView id ->
            "thread:" ++ String.fromInt id

        _ ->
            ""


messageRequestApplies : String -> ActiveRoute -> Bool
messageRequestApplies path route =
    let
        expected =
            case route of
                DmView id ->
                    "/messages?scope=direct&scope_id=" ++ String.fromInt id

                ChannelView id ->
                    "/messages?scope=channel&scope_id=" ++ String.fromInt id

                _ ->
                    ""
    in
    expected /= "" && (path == expected || String.startsWith (expected ++ "&") path)


messageRequest : Int -> String -> E.Value -> E.Value
messageRequest requestId path body =
    E.object [ ( "method", E.string "POST" ), ( "path", E.string path ), ( "body", body ), ( "request_id", E.int requestId ) ]


timelinePath : Message -> String
timelinePath message =
    "/messages?scope=" ++ message.scope ++ "&scope_id=" ++ String.fromInt message.scopeId


relativeTime : Int -> Int -> String
relativeTime now timestamp =
    let
        elapsed =
            agoAt now timestamp
    in
    if elapsed == "now" || elapsed == "1s" then
        "just now"

    else if elapsed == "never" then
        ""

    else
        elapsed ++ " ago"


renderSearchPage : String -> Model -> Html Msg
renderSearchPage q model =
    let
        userCount =
            List.length model.searchUsers

        threadCount =
            List.length model.searchThreads

        messageCount =
            List.length model.searchMessages
    in
    div [ class "search-page page-stack" ]
        [ div [ class "page-heading" ]
            [ div []
                [ span [ class "eyebrow" ] [ text "Search" ]
                , h1 [] [ text ("Results for “" ++ q ++ "”") ]
                , p [ class "muted" ]
                    [ text
                        (String.fromInt userCount
                            ++ " people, "
                            ++ String.fromInt threadCount
                            ++ " discussions, and "
                            ++ String.fromInt messageCount
                            ++ " messages"
                        )
                    ]
                ]
            ]
        , div [ class "search-result-grid" ]
            [ section [ class "card search-result-section" ]
                [ div [ class "search-result-head" ] [ h2 [] [ text "People" ], span [ class "pill" ] [ text (String.fromInt userCount) ] ]
                , div []
                    (if List.isEmpty model.searchUsers then
                        [ div [ class "empty" ] [ text "No people matched this search." ] ]

                     else
                        List.map searchUserView model.searchUsers
                    )
                ]
            , section [ class "card search-result-section" ]
                [ div [ class "search-result-head" ] [ h2 [] [ text "Discussions" ], span [ class "pill" ] [ text (String.fromInt threadCount) ] ]
                , div []
                    (if List.isEmpty model.searchThreads then
                        [ div [ class "empty" ] [ text "No discussions matched this search." ] ]

                     else
                        List.map searchThreadView model.searchThreads
                    )
                ]
            , section [ class "card search-result-section search-message-results" ]
                [ div [ class "search-result-head" ] [ h2 [] [ text "Messages" ], span [ class "pill" ] [ text (String.fromInt messageCount) ] ]
                , div []
                    (if List.isEmpty model.searchMessages then
                        [ div [ class "empty" ] [ text "No readable messages matched this search." ] ]

                     else
                        List.map searchMessageView model.searchMessages
                    )
                ]
            ]
        ]


searchMessageView : Message -> Html Msg
searchMessageView m =
    let
        target =
            if m.scope == "channel" then
                "#channel/" ++ String.fromInt m.scopeId

            else
                "#dm/" ++ String.fromInt m.scopeId

        preview =
            if String.length m.body > 220 then
                String.left 217 m.body ++ "..."

            else
                m.body
    in
    button [ class "row search-message-row", type_ "button", onClick (Go target) ]
        [ avatarImg m.avatarUrl m.displayName "small"
        , div [ class "grow search-message-copy" ]
            [ div [ class "search-message-author" ]
                [ b [] [ text m.displayName ]
                , botBadge m.isBot
                , small [ class "muted" ] [ text ("@" ++ m.username) ]
                ]
            , p [] [ text preview ]
            ]
        ]


searchUserView : User -> Html Msg
searchUserView u =
    div [ class "row search-user-row" ]
        [ avatarImg u.avatarUrl u.displayName ""
        , div [ class "grow clickable-user", onClick (Go ("#profile/" ++ String.fromInt u.id)) ]
            [ b [] [ text u.displayName ], small [ class "muted" ] [ text ("@" ++ u.username) ] ]
        , button [ class "btn", onClick (BridgeEvent "dm_user" (E.int u.id)) ] [ text "Message" ]
        ]


searchThreadView : ForumThread -> Html Msg
searchThreadView t =
    div [ class "row", onClick (Go ("#t/" ++ String.fromInt t.id)) ]
        [ avatarImg t.avatarUrl t.displayName ""
        , div [] [ b [] [ text t.title ], small [ class "muted" ] [ text (t.forumName ++ " · " ++ t.displayName) ] ]
        ]



-- HELPERS


wireCodeFromInput : String -> String
wireCodeFromInput raw =
    let
        value =
            String.trim raw

        markers =
            [ "#/wire/", "#wire/", "#/invite/", "#invite/", "/wire/", "/invite/", "/w/" ]

        afterMarker marker =
            value
                |> String.split marker
                |> List.reverse
                |> List.head
                |> Maybe.withDefault value

        candidate =
            markers
                |> List.filter (\marker -> String.contains marker value)
                |> List.head
                |> Maybe.map afterMarker
                |> Maybe.withDefault value

        before separator input =
            input |> String.split separator |> List.head |> Maybe.withDefault input

        cleaned =
            candidate |> before "?" |> before "&" |> before "#" |> before "/" |> String.trim
    in
    Url.percentDecode cleaned |> Maybe.withDefault cleaned


validAccentColor : String -> Bool
validAccentColor value =
    let
        isHex character =
            Char.isDigit character || List.member (Char.toLower character) [ 'a', 'b', 'c', 'd', 'e', 'f' ]
    in
    String.length value == 7 && String.startsWith "#" value && String.all isHex (String.dropLeft 1 value)


parseRoute : String -> ActiveRoute
parseRoute raw =
    let
        s =
            if String.startsWith "/" raw then
                String.dropLeft 1 raw

            else
                raw
    in
    if s == "" || s == "home" then
        Home

    else if s == "forums" then
        Forums

    else if s == "dms" then
        Dms

    else if s == "friends" then
        Friends

    else if s == "settings" then
        Settings

    else if s == "new-server" then
        NewServer

    else if s == "notifications" then
        Notifications

    else if s == "source" || String.startsWith "source/" s then
        SourceHub

    else if String.startsWith "f/" s then
        ForumView (parseInt (String.dropLeft 2 s))

    else if String.startsWith "t/" s then
        ThreadView (parseInt (String.dropLeft 2 s))

    else if String.startsWith "forum/" s then
        ForumView (parseInt (String.dropLeft 6 s))

    else if String.startsWith "thread/" s then
        ThreadView (parseInt (String.dropLeft 7 s))

    else if String.startsWith "dm/" s then
        DmView (parseInt (String.dropLeft 3 s))

    else if String.startsWith "profile/" s then
        ProfileView (parseInt (String.dropLeft 8 s))

    else if String.startsWith "server/" s then
        ServerView (parseInt (String.dropLeft 7 s))

    else if String.startsWith "channel/" s then
        ChannelView (parseInt (String.dropLeft 8 s))

    else if String.startsWith "voice/" s then
        VoiceChannelView (parseInt (String.dropLeft 6 s))

    else if String.startsWith "wire/" s then
        InviteView (String.dropLeft 5 s)

    else if String.startsWith "invite/" s then
        InviteView (String.dropLeft 7 s)

    else if String.startsWith "search/" s then
        SearchView (String.dropLeft 7 s)

    else
        Home


authTokenFromFragment : String -> String
authTokenFromFragment raw =
    let
        s =
            if String.startsWith "/" raw then
                String.dropLeft 1 raw

            else
                raw
    in
    if String.startsWith "reset/" s then
        String.dropLeft 6 s

    else
        ""


verifyTokenFromFragment : String -> Maybe String
verifyTokenFromFragment raw =
    let
        s =
            if String.startsWith "/" raw then
                String.dropLeft 1 raw

            else
                raw
    in
    if String.startsWith "verify-email/" s then
        let
            token =
                String.dropLeft 13 s
        in
        if String.length token >= 16 then
            Just token

        else
            Nothing

    else
        Nothing


parseInt : String -> Int
parseInt s =
    case String.toInt s of
        Just i ->
            i

        Nothing ->
            0


sortConvs : List Conversation -> List Conversation
sortConvs convs =
    List.sortWith compareConvs convs


compareConvs : Conversation -> Conversation -> Order
compareConvs a b =
    let
        aUnread =
            a.unread > 0

        bUnread =
            b.unread > 0
    in
    case ( aUnread, bUnread ) of
        ( True, False ) ->
            LT

        ( False, True ) ->
            GT

        _ ->
            compare b.updatedAt a.updatedAt


fmtErr : String -> String
fmtErr err =
    case err of
        "invalid_registration" ->
            "Username must be 3-24 characters and password must be at least 10 characters."

        "username_taken" ->
            "That username is already taken."

        "server_exists" ->
            "You already have a server with that name."

        "channel_exists" ->
            "A channel with that name already exists in this server."

        "invalid_server_name" ->
            "Server name must be at least 2 characters."

        "invalid_channel_name" ->
            "Channel name is required."

        "invalid_channel" ->
            "That Wire channel does not belong to this server."

        "invalid_invite" ->
            "That Wire is invalid, expired, or has been revoked."

        "bad_login" ->
            "Username or password is incorrect."

        "invalid_token" ->
            "That link is invalid or has expired. Request a new one."

        "invalid_email" ->
            "Enter a valid email address, or leave it blank."

        "email_taken" ->
            "That email is already verified on another account."

        "email_required" ->
            "Add an email address before requesting a verification message."

        "weak_password" ->
            "Password must be at least 10 characters."

        "mail_disabled" ->
            "This instance is not sending email right now."

        "registration_disabled" ->
            "Registration is disabled on this server."

        "invalid_json" ->
            "Could not send the form. Please try again."

        "database_unavailable" ->
            "The server database is temporarily unavailable."

        "database_timeout" ->
            "The server database timed out. Please try again."

        "rate_limited" ->
            "Too many attempts. Wait a moment and try again."

        "slowmode" ->
            "Slowmode is active in this channel. Wait a little before sending another message."

        "pin_limit" ->
            "This channel already has 50 pinned messages. Unpin one before adding another."

        "pins_channel_only" ->
            "Only server channel messages can be pinned."

        "reaction_rate_limited" ->
            "You’re reacting too quickly. Wait a moment and try again."

        "invalid_reaction" ->
            "That reaction is not supported. Choose one from Plainwire’s reaction picker."

        "confirmation_mismatch" ->
            "The server name did not match. Type it exactly to confirm deletion."

        "user_not_found" ->
            "One or more usernames could not be found. Check the spelling and try again."

        "too_many_members" ->
            "Group chats can contain up to 50 people."

        "invalid_message" ->
            "Messages cannot be empty or contain only spaces."

        "invalid_target" ->
            "That forwarding destination is no longer available."

        "forum_membership_required" ->
            "Join this forum before posting, replying, or voting."

        "forum_owner_cannot_leave" ->
            "The forum owner cannot leave their own forum."

        "thread_locked" ->
            "That thread is locked."

        "role_hierarchy" ->
            "That role or member is at or above your highest manageable role."

        "owner_role_locked" ->
            "The server or group owner role cannot be reassigned."

        "too_many_roles" ->
            "A member can have at most 50 custom roles."

        "invalid_role" ->
            "One of those roles no longer exists in this server."

        "not_found" ->
            "That item no longer exists. Refresh and try again."

        "forbidden" ->
            "That action is not allowed. A user may have blocked one of the selected accounts."

        _ ->
            err |> String.replace "_" " "


decodeApi : E.Value -> Msg
decodeApi val =
    case D.decodeValue apiDecoder val of
        Ok msg ->
            msg

        Err _ ->
            ApiError "" "" Nothing "request_failed"


apiDecoder : Decoder Msg
apiDecoder =
    D.map6 apiMsg
        (D.field "path" D.string)
        (D.field "method" D.string |> defaultValue "GET")
        (D.maybe (D.field "request_id" D.int))
        (D.field "ok" D.bool)
        (D.oneOf [ D.field "data" D.value, D.succeed E.null ])
        (D.oneOf [ D.field "error" D.string, D.succeed "request_failed" ])


apiMsg : String -> String -> Maybe Int -> Bool -> E.Value -> String -> Msg
apiMsg path method requestId ok data err =
    if ok then
        ApiSuccess path method requestId data

    else
        ApiError path method requestId err


fromApiField : String -> E.Value -> E.Value
fromApiField name val =
    case D.decodeValue (D.field name D.value) val of
        Ok v ->
            v

        Err _ ->
            E.null


fromApiFieldStr : String -> E.Value -> String
fromApiFieldStr name val =
    case D.decodeValue (D.field name D.string) val of
        Ok v ->
            v

        Err _ ->
            ""


fromApiFieldInt : String -> E.Value -> Int
fromApiFieldInt name val =
    case D.decodeValue (D.field name D.int) val of
        Ok v ->
            v

        Err _ ->
            0


maybeInt : Maybe Int -> E.Value
maybeInt value =
    case value of
        Just i ->
            E.int i

        Nothing ->
            E.null


maybeIntString : Maybe Int -> String
maybeIntString value =
    case value of
        Just i ->
            String.fromInt i

        Nothing ->
            ""


csvInts : String -> List Int
csvInts value =
    value
        |> String.split ","
        |> List.filterMap (String.trim >> String.toInt)
        |> List.filter (\i -> i > 0)


csvUsernames : String -> List String
csvUsernames value =
    value
        |> String.split ","
        |> List.map normalizeUsernameInput
        |> List.filter (not << String.isEmpty)
        |> uniqueStrings


uniqueStrings : List String -> List String
uniqueStrings values =
    List.foldl
        (\value found ->
            if List.member value found then
                found

            else
                found ++ [ value ]
        )
        []
        values


normalizeUsernameInput : String -> String
normalizeUsernameInput value =
    let
        trimmed =
            String.trim value
    in
    String.toLower
        (if String.startsWith "@" trimmed then
            String.dropLeft 1 trimmed

         else
            trimmed
        )


encodeServer : Server -> E.Value
encodeServer server =
    E.object
        [ ( "id", E.int server.id )
        , ( "name", E.string server.name )
        , ( "description", E.string server.description )
        , ( "welcome_message", E.string server.welcomeMessage )
        , ( "icon_url", E.string server.iconUrl )
        , ( "banner_url", E.string server.bannerUrl )
        , ( "accent_color", E.string server.accentColor )
        ]



