module View.Settings exposing (renderSettingsPage)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as D
import Json.Encode as E
import Types exposing (..)
import View.Ui exposing (..)


themeChoiceCard : Bool -> String -> String -> String -> Msg -> Html Msg
themeChoiceCard selected theme heading copy msg =
    button
        [ type_ "button"
        , class
            ("choice-card theme-choice"
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
        [ span [ class ("theme-preview theme-preview-" ++ theme), attribute "aria-hidden" "true" ]
            [ span [ class "theme-preview-rail" ] []
            , span [ class "theme-preview-panel" ] []
            ]
        , span [ class "choice-card-copy" ]
            [ b [] [ text heading ]
            , small [ class "muted" ] [ text copy ]
            ]
        , span [ class "choice-card-check", attribute "aria-hidden" "true" ] []
        ]


renderSettingsPage : Model -> Html Msg
renderSettingsPage model =
    case model.me of
        Just u ->
            div [ class "settings-page" ]
                [ nav [ class "settings-mobile-nav", attribute "aria-label" "Settings sections" ]
                    [ settingsMobileTab model.settingsTab "profile" "Profile"
                    , settingsMobileTab model.settingsTab "appearance" "Appearance"
                    , settingsMobileTab model.settingsTab "chat" "Chat"
                    , settingsMobileTab model.settingsTab "voice" "Voice"
                    , settingsMobileTab model.settingsTab "sound" "Alerts"
                    , settingsMobileTab model.settingsTab "privacy" "Privacy"
                    , settingsMobileTab model.settingsTab "account" "Account"
                    , settingsMobileTab model.settingsTab "developer" "Developer"
                    ]
                , aside [ class "settings-sidebar" ]
                    [ div [ class "settings-nav-label" ] [ text "User settings" ]
                    , settingsDesktopTab model.settingsTab "profile" "ui-icon ui-icon-profile" "Profile" "Identity and bio"
                    , settingsDesktopTab model.settingsTab "appearance" "ui-icon ui-icon-settings" "Appearance" "Theme and layout"
                    , settingsDesktopTab model.settingsTab "chat" "ui-icon ui-icon-messages" "Chat" "Compose and media"
                    , settingsDesktopTab model.settingsTab "voice" "call-icon call-icon-audio" "Voice & Video" "Devices and sharing"
                    , settingsDesktopTab model.settingsTab "sound" "ui-icon ui-icon-notifications" "Notifications" "Alerts and sounds"
                    , settingsDesktopTab model.settingsTab "privacy" "ui-icon ui-icon-profile" "Privacy & Safety" "Local data controls"
                    , div [ class "settings-nav-separator" ] []
                    , settingsDesktopTab model.settingsTab "account" "ui-icon ui-icon-settings" "Account" "Security and sessions"
                    , settingsDesktopTab model.settingsTab "developer" "ui-icon ui-icon-settings" "Developer" "Apps, bots and commands"
                    , div [ class "settings-nav-footer" ]
                        [ span [ class "settings-saved-dot", attribute "aria-hidden" "true" ] []
                        , div [] [ b [] [ text "Saved on this device" ], small [] [ text "Most changes apply immediately" ] ]
                        ]
                    ]
                , div [ class "settings-content" ]
                    [ div [ class "settings-content-top" ]
                        [ div [ class "settings-heading" ]
                            [ span [ class "eyebrow" ] [ text "Personal settings" ]
                            , h1 [] [ text (settingsTitle model.settingsTab) ]
                            , p [ class "settings-subtitle" ] [ text (settingsSubtitle model.settingsTab) ]
                            ]
                        , span [ class "settings-user-chip" ] [ avatarImg u.avatarUrl u.displayName "small", text ("@" ++ u.username) ]
                        ]
                    , div [ class "settings-search" ]
                        [ div [ class "settings-search-field" ]
                            [ span [ class "ui-icon ui-icon-search", attribute "aria-hidden" "true" ] []
                            , input [ type_ "search", value model.settingsSearch, placeholder "Find a setting…", attribute "aria-label" "Find a setting", onInput SettingsSearch ] []
                            , if String.isEmpty model.settingsSearch then
                                text ""

                              else
                                button [ type_ "button", class "settings-search-clear", onClick (SettingsSearch ""), attribute "aria-label" "Clear settings search" ] [ text "Clear" ]
                            ]
                        , renderSettingsSearch model.settingsSearch
                        ]
                    , div [ class "settings-content-inner" ]
                        [ case model.settingsTab of
                            "appearance" ->
                                renderAppearanceSettings model

                            "chat" ->
                                renderChatSettings model

                            "voice" ->
                                renderVoiceSettings model

                            "sound" ->
                                renderNotificationSettings model

                            "privacy" ->
                                renderPrivacySettings model

                            "account" ->
                                renderAccountSettings u model

                            "developer" ->
                                node "pw-developer-portal" [] []

                            _ ->
                                renderProfileSettings u model
                        ]
                    ]
                ]

        Nothing ->
            text ""


renderSettingsSearch : String -> Html Msg
renderSettingsSearch query =
    let
        sections =
            [ ( "profile", "Profile", "Name, avatar, banner and bio" )
            , ( "appearance", "Appearance", "Theme, colors, system default and density" )
            , ( "chat", "Chat", "Messages, enter to send, time and media" )
            , ( "voice", "Voice & audio", "Microphone, speaker, noise suppression and test" )
            , ( "sound", "Notifications", "Sounds, chimes, volume and desktop alerts" )
            , ( "privacy", "Privacy", "Drafts, local storage and preferences" )
            , ( "account", "Account", "Username, handle, password, sessions, security and connection diagnostics" )
            ]

        matches =
            List.filter (\( _, name, detail ) -> String.contains (String.toLower (String.trim query)) (String.toLower (name ++ " " ++ detail))) sections
    in
    if String.isEmpty (String.trim query) then
        text ""

    else
        div [ class "settings-search-results", attribute "aria-live" "polite" ]
            (if List.isEmpty matches then
                [ p [ class "muted" ] [ text "No matching settings. Try microphone, theme, or password." ] ]

             else
                List.map (\( key, name, detail ) -> button [ type_ "button", onClick (SetSettingsTab key) ] [ b [] [ text name ], small [] [ text detail ] ]) matches
            )


settingsMobileTab : String -> String -> String -> Html Msg
settingsMobileTab current key label =
    button
        [ type_ "button"
        , class
            ("settings-mobile-tab"
                ++ (if current == key then
                        " active"

                    else
                        ""
                   )
            )
        , onClick (SetSettingsTab key)
        , attribute "aria-current"
            (if current == key then
                "page"

             else
                "false"
            )
        ]
        [ text label ]


settingsDesktopTab : String -> String -> String -> String -> String -> Html Msg
settingsDesktopTab current key iconClass label detail =
    button
        [ type_ "button"
        , class
            ("settings-tab"
                ++ (if current == key then
                        " active"

                    else
                        ""
                   )
            )
        , attribute "data-setting" key
        , attribute "aria-current"
            (if current == key then
                "page"

             else
                "false"
            )
        , onClick (SetSettingsTab key)
        ]
        [ span [ class "settings-tab-icon", attribute "aria-hidden" "true" ]
            [ span [ class iconClass ] [] ]
        , span [ class "settings-tab-copy" ]
            [ b [] [ text label ]
            , small [ attribute "aria-hidden" "true" ] [ text detail ]
            ]
        ]


settingsChoice : Bool -> String -> Msg -> Html Msg
settingsChoice isSelected label message =
    button
        [ type_ "button"
        , class
            ("btn secondary"
                ++ (if isSelected then
                        " active-choice"

                    else
                        ""
                   )
            )
        , onClick message
        , attribute "aria-pressed"
            (if isSelected then
                "true"

             else
                "false"
            )
        ]
        [ text label ]


settingsTitle : String -> String
settingsTitle tab =
    case tab of
        "appearance" ->
            "Appearance"

        "chat" ->
            "Chat"

        "voice" ->
            "Voice & Video"

        "sound" ->
            "Notifications"

        "privacy" ->
            "Privacy & Safety"

        "account" ->
            "Account"

        "developer" ->
            "Developer Portal"

        _ ->
            "My Profile"


settingsSubtitle : String -> String
settingsSubtitle tab =
    case tab of
        "appearance" ->
            "Adjust the interface for this browser. Changes preview as you choose them."

        "chat" ->
            "Set how messages, links, and animated media behave."

        "voice" ->
            "Choose audio devices, test your microphone, and tune screen sharing."

        "sound" ->
            "Control browser notifications and preview every sound before enabling it."

        "privacy" ->
            "Review the data and preferences kept locally in this browser."

        "account" ->
            "Manage your sign-in, active sessions, and connection diagnostics."

        "developer" ->
            "Build applications, install bots, register commands, and connect external services or AI models."

        _ ->
            "Update the name, photo, banner, and bio people see across Plainwire."


renderAccountSettings : User -> Model -> Html Msg
renderAccountSettings user model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ]
            [ h2 [] [ text "Account" ]
            , p [ class "muted" ] [ text "Your Plainwire identity and session." ]
            ]
        , div [ class "setting-row" ]
            [ div []
                [ b [] [ text ("@" ++ user.username) ]
                , small [ class "muted" ] [ text ("User ID " ++ String.fromInt user.id) ]
                ]
            , span [ class "pill" ] [ text "Signed in" ]
            ]
        , div [ class "setting-row" ]
            [ div []
                [ b [] [ text "Email" ]
                , small [ class "muted" ]
                    [ text
                        (if String.isEmpty (String.trim user.email) then
                            "No email on this account. Password reset needs a verified address."

                         else if user.emailVerified then
                            user.email ++ " · verified"

                         else
                            user.email ++ " · waiting for verification"
                        )
                    ]
                ]
            , span
                [ class
                    ("pill"
                        ++ (if user.emailVerified then
                                ""

                            else
                                " warn"
                           )
                    )
                ]
                [ text
                    (if String.isEmpty (String.trim user.email) then
                        "Not set"

                     else if user.emailVerified then
                        "Verified"

                     else
                        "Unverified"
                    )
                ]
            ]
        , div [ class "account-action-grid" ]
            [ button [ class "settings-action-card", onClick (BridgeEvent "account_change_username" (E.string user.username)) ]
                [ b [] [ text "Change username" ], small [ class "muted" ] [ text "Change your global @handle without changing your account identity, servers, roles, or DMs." ] ]
            , button [ class "settings-action-card", onClick (BridgeEvent "account_change_email" (E.string user.email)) ]
                [ b [] [ text "Email and verification" ], small [ class "muted" ] [ text "Add or change the address used for password reset. Unverified addresses cannot reset a password." ] ]
            , button [ class "settings-action-card", onClick (BridgeEvent "account_change_password" E.null) ]
                [ b [] [ text "Change password" ], small [ class "muted" ] [ text "Update your password and sign out other sessions." ] ]
            , button [ class "settings-action-card", onClick (BridgeEvent "account_sessions" E.null) ]
                [ b [] [ text "Active sessions" ], small [ class "muted" ] [ text "Review where your account is currently signed in." ] ]
            , button [ class "settings-action-card", onClick (BridgeEvent "account_diagnostics" E.null) ]
                [ b [] [ text "Connection diagnostics" ], small [ class "muted" ] [ text "Check WebSocket, database, browser, and TURN readiness." ] ]
            , button [ class "settings-action-card", onClick (BridgeEvent "replay_onboarding" E.null) ]
                [ b [] [ text "Replay Plainwire tour" ], small [ class "muted" ] [ text "Walk through messages, servers, forums, calls, and shortcuts again." ] ]
            ]
        , div [ class "setting-row settings-about-row" ]
            [ div [] [ b [] [ text "Plainwire" ], small [ class "muted" ] [ text ("Version " ++ model.clientVersion) ] ]
            , span [ class "pill" ] [ text "Web client" ]
            ]
        , div [ class "danger-zone" ]
            [ div []
                [ b [] [ text "Account lifecycle" ]
                , p [ class "muted" ] [ text "Log out, temporarily disable the account, or permanently delete it and its account row." ]
                ]
            , div [ class "danger-zone-actions" ]
                [ button [ class "btn secondary", onClick Logout ] [ text "Log out" ]
                , button [ class "btn danger", onClick (BridgeEvent "account_disable" E.null) ] [ text "Disable account" ]
                , button [ class "btn danger", onClick (BridgeEvent "account_delete" E.null) ] [ text "Delete account" ]
                ]
            ]
        ]


renderChatSettings : Model -> Html Msg
renderChatSettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Chat" ], p [ class "muted" ] [ text "Tune message composition and media behavior on this device." ] ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Send message with Enter" ], small [ class "muted" ] [ text "Choose whether Enter sends or adds a new line." ] ]
            , div [ class "segmented-control" ]
                [ settingsChoice model.chatEnterSends "Enter sends" (SetChatEnterSends True)
                , settingsChoice (not model.chatEnterSends) "Ctrl/Cmd + Enter sends" (SetChatEnterSends False)
                ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Link previews" ], small [ class "muted" ] [ text "Show rich cards for supported links." ] ] ]
            , button
                [ class
                    ("settings-switch"
                        ++ (if model.linkPreviewsEnabled then
                                " active"

                            else
                                ""
                           )
                    )
                , onClick (SetLinkPreviewsEnabled (not model.linkPreviewsEnabled))
                , attribute "role" "switch"
                , attribute "aria-checked"
                    (if model.linkPreviewsEnabled then
                        "true"

                     else
                        "false"
                    )
                , title "Toggle link previews"
                ]
                [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Autoplay animated media" ], small [ class "muted" ] [ text "Control GIF and animated image playback." ] ] ]
            , button
                [ class
                    ("settings-switch"
                        ++ (if model.animatedMediaEnabled then
                                " active"

                            else
                                ""
                           )
                    )
                , onClick (SetAnimatedMediaEnabled (not model.animatedMediaEnabled))
                , attribute "role" "switch"
                , attribute "aria-checked"
                    (if model.animatedMediaEnabled then
                        "true"

                     else
                        "false"
                    )
                , title "Toggle animated media"
                ]
                [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Compact message spacing" ], small [ class "muted" ] [ text "Reduce vertical spacing between grouped messages." ] ] ]
            , button
                [ class
                    ("settings-switch"
                        ++ (if model.compactMessages then
                                " active"

                            else
                                ""
                           )
                    )
                , onClick (SetCompactMessages (not model.compactMessages))
                , attribute "role" "switch"
                , attribute "aria-checked"
                    (if model.compactMessages then
                        "true"

                     else
                        "false"
                    )
                , title "Toggle compact message spacing"
                ]
                [ span [ class "settings-switch-knob" ] [] ]
            ]
        ]


renderPrivacySettings : Model -> Html Msg
renderPrivacySettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Privacy & Safety" ], p [ class "muted" ] [ text "Control browser-side privacy behavior and review account security." ] ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Media preloading" ], small [ class "muted" ] [ text "Preload remote images for smoother scrolling." ] ] ]
            , button
                [ class
                    ("settings-switch"
                        ++ (if model.mediaPreloadEnabled then
                                " active"

                            else
                                ""
                           )
                    )
                , onClick (SetMediaPreloadEnabled (not model.mediaPreloadEnabled))
                , attribute "role" "switch"
                , attribute "aria-checked"
                    (if model.mediaPreloadEnabled then
                        "true"

                     else
                        "false"
                    )
                , title "Toggle media preloading"
                ]
                [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Clear local drafts" ], small [ class "muted" ] [ text "Remove message drafts saved in this browser." ] ] ]
            , button [ class "btn secondary settings-action", onClick (BridgeEvent "privacy_clear_drafts" E.null) ] [ text "Clear drafts" ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Reset device preferences" ], small [ class "muted" ] [ text "Restore layout, chat, audio, and appearance settings on this device." ] ] ]
            , button [ class "btn secondary settings-action", onClick (BridgeEvent "privacy_reset_device" E.null) ] [ text "Reset" ]
            ]
        ]


renderAppearanceSettings : Model -> Html Msg
renderAppearanceSettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Appearance" ], p [ class "muted" ] [ text "Make Plainwire feel comfortable on this device." ] ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Theme" ], small [ class "muted" ] [ text "Use your system colors or choose a theme." ] ]
            , div [ class "appearance-choice-grid" ]
                [ themeChoiceCard (model.profileTheme == "system") "system" "System" "Follow this device." (ProfileTheme "system")
                , themeChoiceCard (model.profileTheme == "dark") "dark" "Dark" "Dim, focused surfaces." (ProfileTheme "dark")
                , themeChoiceCard (model.profileTheme == "light") "light" "Light" "Bright and clean." (ProfileTheme "light")
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Interface density" ], small [ class "muted" ] [ text "Compact mode fits more channels and messages on screen." ] ]
            , div [ class "segmented-control" ]
                [ settingsChoice (model.uiDensity == "comfortable") "Comfortable" (BridgeEvent "ui_density" (E.string "comfortable"))
                , settingsChoice (model.uiDensity == "compact") "Compact" (BridgeEvent "ui_density" (E.string "compact"))
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Text size" ], small [ class "muted" ] [ text "Scale the interface without changing your browser zoom." ] ]
            , div [ class "segmented-control" ]
                [ settingsChoice (model.uiFontScale == "small") "Small" (BridgeEvent "ui_font_scale" (E.string "small"))
                , settingsChoice (model.uiFontScale == "default") "Default" (BridgeEvent "ui_font_scale" (E.string "default"))
                , settingsChoice (model.uiFontScale == "large") "Large" (BridgeEvent "ui_font_scale" (E.string "large"))
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Accent" ], small [ class "muted" ] [ text "Choose the main interface color on this device." ] ]
            , div [ class "segmented-control" ]
                [ settingsChoice (model.uiAccent == "blue") "Blue" (BridgeEvent "ui_accent" (E.string "blue"))
                , settingsChoice (model.uiAccent == "teal") "Teal" (BridgeEvent "ui_accent" (E.string "teal"))
                , settingsChoice (model.uiAccent == "green") "Green" (BridgeEvent "ui_accent" (E.string "green"))
                , settingsChoice (model.uiAccent == "amber") "Amber" (BridgeEvent "ui_accent" (E.string "amber"))
                , settingsChoice (model.uiAccent == "rose") "Rose" (BridgeEvent "ui_accent" (E.string "rose"))
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Corners" ], small [ class "muted" ] [ text "Keep the interface tight or give panels a little more rounding." ] ]
            , div [ class "segmented-control" ]
                [ settingsChoice (model.uiCornerStyle == "compact") "Compact" (BridgeEvent "ui_corner_style" (E.string "compact"))
                , settingsChoice (model.uiCornerStyle == "default") "Default" (BridgeEvent "ui_corner_style" (E.string "default"))
                , settingsChoice (model.uiCornerStyle == "rounded") "Rounded" (BridgeEvent "ui_corner_style" (E.string "rounded"))
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Motion" ], small [ class "muted" ] [ text "Reduce interface animation when you prefer less movement." ] ]
            , div [ class "segmented-control" ]
                [ settingsChoice (not model.reduceMotion) "Standard" (BridgeEvent "reduce_motion" (E.bool False))
                , settingsChoice model.reduceMotion "Reduced" (BridgeEvent "reduce_motion" (E.bool True))
                ]
            ]
        , div [ class "setting-row" ]
            [ div []
                [ b [] [ text "Themes & plugins" ]
                , small [ class "muted" ] [ text "Install client-side Less themes and sandboxed plugins for this browser." ]
                ]
            , button [ class "btn secondary settings-action", onClick (BridgeEvent "open_extensions" E.null) ] [ text "Manage" ]
            ]
        ]


renderNotificationSettings : Model -> Html Msg
renderNotificationSettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Notifications" ], p [ class "muted" ] [ text "Control alerts on this device." ] ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Sound effects" ], small [ class "muted" ] [ text "Play sounds for messages, calls, and important activity." ] ] ]
            , button
                [ class
                    ("settings-switch"
                        ++ (if model.soundEnabled then
                                " active"

                            else
                                ""
                           )
                    )
                , onClick ToggleSound
                , attribute "role" "switch"
                , attribute "aria-checked"
                    (if model.soundEnabled then
                        "true"

                     else
                        "false"
                    )
                , title "Toggle sound effects"
                ]
                [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Desktop notifications" ], small [ class "muted" ] [ text "Get alerts while Plainwire is open in the background." ] ] ]
            , button [ class "btn secondary settings-action", onClick (BridgeEvent "request_notifications" E.null) ] [ text "Review permission" ]
            ]
        , div [ class "notification-sound-preview" ]
            [ div [] [ b [] [ text "Sound preview" ], small [ class "muted" ] [ text "Short, soft cues designed to stay out of the way." ] ]
            , div [ class "sound-preview-list" ]
                [ button [ class "sound-preview-btn", onClick (BridgeEvent "preview_sound" (E.string "notification")) ] [ span [ class "ui-icon ui-icon-notifications", attribute "aria-hidden" "true" ] [], span [] [ b [] [ text "Message" ], small [] [ text "A soft two-note bell" ] ], span [ class "sound-preview-action" ] [ text "Play" ] ]
                , button [ class "sound-preview-btn", onClick (BridgeEvent "preview_sound" (E.string "incoming")) ] [ span [ class "ui-icon ui-icon-call", attribute "aria-hidden" "true" ] [], span [] [ b [] [ text "Incoming call" ], small [] [ text "A warm, rising chime" ] ], span [ class "sound-preview-action" ] [ text "Play" ] ]
                , button [ class "sound-preview-btn", onClick (BridgeEvent "preview_sound" (E.string "outgoing")) ] [ span [ class "ui-icon ui-icon-call", attribute "aria-hidden" "true" ] [], span [] [ b [] [ text "Calling" ], small [] [ text "A quiet waiting tone" ] ], span [ class "sound-preview-action" ] [ text "Play" ] ]
                ]
            ]
        ]


renderVoiceSettings : Model -> Html Msg
renderVoiceSettings model =
    let
        deviceOptions devices =
            option [ value "" ] [ text "System default" ]
                :: List.map (\device -> option [ value device.id ] [ text device.label ]) devices

        level =
            String.fromInt (Basics.max 0 (Basics.min 100 model.micTestLevel)) ++ "%"

        processingButton processingMode heading copy enabled =
            button
                [ type_ "button"
                , class
                    ("voice-mode"
                        ++ (if model.voiceProcessingMode == processingMode then
                                " active"

                            else
                                ""
                           )
                    )
                , onClick (SelectVoiceProcessing processingMode)
                , disabled (not enabled)
                , attribute "aria-pressed"
                    (if model.voiceProcessingMode == processingMode then
                        "true"

                     else
                        "false"
                    )
                ]
                [ span [ class "voice-mode-title" ] [ text heading ]
                , span [ class "voice-mode-copy" ] [ text copy ]
                ]
    in
    div [ class "settings-card settings-panel voice-settings" ]
        [ div [ class "settings-card-head" ]
            [ h2 [] [ text "Voice & Video" ]
            , p [ class "muted" ] [ text "Choose devices, verify your microphone, and set how screen sharing works before joining friends." ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Input device" ], small [ class "muted" ] [ text "The microphone used in calls and voice channels." ] ]
            , select [ value model.selectedAudioInput, onInput SelectAudioInput, attribute "aria-label" "Input device" ] (deviceOptions model.audioInputs)
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ Html.node "pw-input-volume" [] []
            , small [ class "muted" ] [ text "Applies immediately to calls and mic tests. Boost above 100% can distort loud microphones. Listening volume is adjustable for each person in call details." ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div []
                [ b [] [ text "Output device" ]
                , small [ class "muted" ]
                    [ text
                        (if model.outputSelectionSupported then
                            "Where call audio plays."

                         else
                            "This browser uses your system output device."
                        )
                    ]
                ]
            , select [ value model.selectedAudioOutput, onInput SelectAudioOutput, attribute "aria-label" "Output device", disabled (not model.outputSelectionSupported) ] (deviceOptions model.audioOutputs)
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div []
                [ b [] [ text "Microphone processing" ]
                , small [ class "muted" ] [ text "Pick a lightweight everyday mode or preserve the microphone's natural signal." ]
                ]
            , div [ class "voice-mode-grid", attribute "role" "group", attribute "aria-label" "Microphone processing mode" ]
                [ processingButton "noise" "Noise cancelling" "Browser echo control, noise reduction, and automatic level." True
                , processingButton "studio" "Studio mic" "Unprocessed, full-band input for a quiet room and headphones." True
                , processingButton "krisp"
                    "Krisp AI"
                    (if model.krispAvailable then
                        "Licensed Krisp processing is ready on this server."

                     else
                        "Add the licensed Krisp browser SDK and models to enable."
                    )
                    model.krispAvailable
                ]
            ]
        , div [ class "setting-row setting-row-stack mic-test-card" ]
            [ div [] [ b [] [ text "Mic test" ], small [ class "muted" ] [ text "Speak normally. The meter and playback use the selected processing mode." ] ]
            , div [ class "mic-meter", attribute "role" "meter", attribute "aria-label" "Microphone input level", attribute "aria-valuenow" (String.fromInt model.micTestLevel), attribute "aria-valuemin" "0", attribute "aria-valuemax" "100" ]
                [ span [ class "mic-meter-fill", style "width" level ] []
                , span [ class "mic-meter-peak" ] []
                ]
            , div [ class "mic-test-actions" ]
                [ button
                    [ class
                        ("btn "
                            ++ (if model.micTesting then
                                    "danger"

                                else
                                    "secondary"
                               )
                        )
                    , onClick ToggleMicTest
                    ]
                    [ text
                        (if model.micTesting then
                            "Stop test"

                         else
                            "Test microphone"
                        )
                    ]
                , button
                    [ class
                        ("btn secondary"
                            ++ (if model.micMonitoring then
                                    " active"

                                else
                                    ""
                               )
                        )
                    , onClick ToggleMicMonitor
                    , disabled (not model.micTesting)
                    , attribute "aria-pressed"
                        (if model.micMonitoring then
                            "true"

                         else
                            "false"
                        )
                    , title "Use headphones to avoid feedback"
                    ]
                    [ text
                        (if model.micMonitoring then
                            "Stop playback"

                         else
                            "Hear myself"
                        )
                    ]
                , button [ class "btn ghost", onClick (BridgeEvent "list_audio_devices" E.null) ] [ text "Refresh devices" ]
                ]
            , if model.micMonitoring then
                small [ class "mic-monitor-warning" ] [ text "Playback is on. Wear headphones to prevent feedback." ]

              else
                text ""
            ]
        , Html.node "pw-screen-settings" [ class "settings-screen-share-control" ] []
        , div [ class "voice-settings-note" ]
            [ b [] [ text "Having trouble being heard?" ]
            , p [ class "muted" ] [ text "Choose your microphone, start a test, and speak. The meter should move. Check your headset’s mute switch if it stays still. You can change devices during a call." ]
            ]
        ]


renderProfileSettings : User -> Model -> Html Msg
renderProfileSettings u model =
    div [ class "settings-card profile-settings-card" ]
        [ div
            [ class "settings-banner"
            , style "background-image"
                (if String.isEmpty model.profileBannerPreviewUrl then
                    "none"

                 else
                    cssImage model.profileBannerPreviewUrl
                )
            ]
            [ div [ class "settings-avatar-wrap" ] [ avatarImg model.profileAvatarPreviewUrl model.profileDisplayName "" ]
            , div [ class "settings-name-block" ]
                [ h2 []
                    [ text
                        (if String.isEmpty model.profileDisplayName then
                            u.displayName

                         else
                            model.profileDisplayName
                        )
                    ]
                , p [ class "muted" ] [ text ("@" ++ u.username) ]
                ]
            ]
        , div [ class "settings-fields" ]
            [ div [ class "field" ]
                [ div [ class "field-label-row" ]
                    [ label [ for "profile-display-name" ] [ text "Display name" ]
                    , small [ class "field-count" ] [ text (String.fromInt (String.length model.profileDisplayName) ++ " / 48") ]
                    ]
                , input [ id "profile-display-name", value model.profileDisplayName, maxlength 48, onInput ProfileDisplayName ] []
                ]
            , div [ class "field" ]
                [ div [ class "field-label-row" ]
                    [ label [ for "profile-bio" ] [ text "Bio" ]
                    , small [ class "field-count" ] [ text (String.fromInt (String.length model.profileBio) ++ " / 600") ]
                    ]
                , textarea [ id "profile-bio", value model.profileBio, maxlength 600, onInput ProfileBio ] []
                ]
            , div [ class "field" ]
                [ label [ for "profile-avatar-url" ] [ text "Avatar URL" ]
                , input [ id "profile-avatar-url", value model.profileAvatarUrl, placeholder "https://...", onInput ProfileAvatarUrl ] []
                , div [ class "file-picker-row" ]
                    [ input [ id "profileAvatarFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "profileAvatarFile")) ] []
                    , label
                        [ class
                            ("btn secondary file-picker-button"
                                ++ (if model.profileAvatarUploading then
                                        " disabled"

                                    else
                                        ""
                                   )
                            )
                        , attribute "for" "profileAvatarFile"
                        , attribute "aria-disabled"
                            (if model.profileAvatarUploading then
                                "true"

                             else
                                "false"
                            )
                        ]
                        [ text
                            (if model.profileAvatarUploading then
                                "Uploading..."

                             else
                                "Choose avatar"
                            )
                        ]
                    , small [ class "muted" ] [ text "JPEG, PNG, GIF, WebP, or AVIF" ]
                    ]
                ]
            , div [ class "field" ]
                [ label [ for "profile-banner-url" ] [ text "Banner URL" ]
                , input [ id "profile-banner-url", value model.profileBannerUrl, placeholder "https://...", onInput ProfileBannerUrl ] []
                , div [ class "file-picker-row" ]
                    [ input [ id "profileBannerFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "profileBannerFile")) ] []
                    , label
                        [ class
                            ("btn secondary file-picker-button"
                                ++ (if model.profileBannerUploading then
                                        " disabled"

                                    else
                                        ""
                                   )
                            )
                        , attribute "for" "profileBannerFile"
                        , attribute "aria-disabled"
                            (if model.profileBannerUploading then
                                "true"

                             else
                                "false"
                            )
                        ]
                        [ text
                            (if model.profileBannerUploading then
                                "Uploading..."

                             else
                                "Choose banner"
                            )
                        ]
                    , small [ class "muted" ] [ text "JPEG, PNG, GIF, WebP, or AVIF" ]
                    ]
                ]
            , div [ class "field" ]
                [ label [ for "profile-status" ] [ text "Status" ]
                , select [ id "profile-status", value model.profileStatus, onInput ProfileStatus ]
                    [ option [ value "online" ] [ text "Online (auto idle)" ]
                    , option [ value "away" ] [ text "Away" ]
                    , option [ value "busy" ] [ text "Busy" ]
                    , option [ value "invisible" ] [ text "Invisible" ]
                    ]
                , small [ class "muted" ] [ text "Online turns to away automatically when you stop using Plainwire. Invisible shows you as offline." ]
                ]
            , div [ class "nav-actions" ]
                [ button
                    [ class "btn"
                    , onClick SaveProfile
                    , disabled (model.profileAvatarUploading || model.profileBannerUploading)
                    ]
                    [ text
                        (if model.profileAvatarUploading || model.profileBannerUploading then
                            "Uploading image…"

                         else
                            "Save profile"
                        )
                    ]
                ]
            ]
        ]

