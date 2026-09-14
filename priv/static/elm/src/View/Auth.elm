module View.Auth exposing (ready, validationError, view)

import Html exposing (Html, b, button, div, h1, h2, input, label, main_, p, section, small, span, text)
import Html.Attributes exposing (attribute, class, disabled, id, maxlength, placeholder, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Types exposing (Model, Msg(..))


view : Model -> Html Msg
view model =
    div [ class "auth-shell" ]
        [ section [ class "auth-brand-panel" ]
            [ div [ class "auth-brand-lockup" ]
                [ div [ class "auth-brand-mark" ] []
                , span [] [ text model.appName ]
                ]
            , div [ class "auth-brand-copy" ]
                [ span [ class "eyebrow" ] [ text "Stay in the conversation" ]
                , h1 [] [ text "A place for your people." ]
                , p []
                    [ text
                        (if String.isEmpty model.instanceDescription then
                            "Messages, calls, communities, and files on one self-hosted server."

                         else
                            model.instanceDescription
                        )
                    ]
                ]
            , div [ class "auth-capabilities", attribute "aria-label" "Plainwire features" ]
                (List.map (\feature -> span [] [ text feature ]) [ "Messages", "Voice", "Screen sharing", "Forums", "Files" ])
            ]
        , main_ [ class "auth-form-panel" ]
            [ div [ class "auth-form-wrap" ]
                [ div [ class "auth-mobile-brand" ]
                    [ div [ class "auth-brand-mark" ] []
                    , b [] [ text model.appName ]
                    ]
                , div [ class "auth-heading" ]
                    [ h2 []
                        [ text
                            (if model.authMode == "login" then
                                "Welcome back"

                             else
                                "Create your account"
                            )
                        ]
                    , p [ class "muted" ]
                        [ text
                            (if model.authMode == "login" then
                                "Sign in to continue to " ++ model.appName ++ "."

                             else
                                "Set up an account on this Plainwire instance."
                            )
                        ]
                    ]
                , modeSwitch model
                , Html.form [ class "auth-fields", onSubmit DoAuth ]
                    [ field "u" "Username"
                        [ type_ "text"
                        , attribute "autocomplete" "username"
                        , attribute "autocapitalize" "none"
                        , attribute "spellcheck" "false"
                        , maxlength 24
                        , placeholder "yourname"
                        , value model.authUsername
                        , onInput AuthUsername
                        ]
                    , if model.authMode == "register" then
                        field "d" "Display name"
                            [ type_ "text"
                            , attribute "autocomplete" "name"
                            , maxlength 48
                            , placeholder "How people see you"
                            , value model.authDisplayName
                            , onInput AuthDisplayName
                            ]

                      else
                        text ""
                    , passwordField model
                    , if model.authMode == "register" then
                        div [ class "auth-password-meter" ]
                            [ div [ class ("auth-password-bar strength-" ++ passwordStrength model.authPassword) ] []
                            , small [ class "muted" ] [ text "Use at least 10 characters. A longer unique passphrase is best." ]
                            ]

                      else
                        text ""
                    , if model.authMode == "register" then
                        field "pc" "Confirm password"
                            [ type_
                                (if model.authPasswordVisible then
                                    "text"

                                 else
                                    "password"
                                )
                            , attribute "autocomplete" "new-password"
                            , maxlength 256
                            , value model.authPasswordConfirm
                            , onInput AuthPasswordConfirm
                            ]

                      else
                        text ""
                    , validationMessage model
                    , button [ type_ "submit", class "btn auth-submit", disabled (model.authBusy || not (ready model)) ]
                        [ text
                            (if model.authBusy then
                                "Working…"

                             else if model.authMode == "login" then
                                "Sign in"

                             else
                                "Create account"
                            )
                        ]
                    ]
                , p [ class "auth-footnote" ]
                    [ text
                        (if model.registrationEnabled then
                            "Private by design. Hosted by your community."

                         else
                            "Registration is closed on this server. Sign in with an existing account."
                        )
                    ]
                , div [ class "auth-instance-meta" ]
                    [ span [] [ text ("Plainwire " ++ model.clientVersion) ]
                    , span [ attribute "aria-hidden" "true" ] [ text "·" ]
                    , span [] [ text "Web client" ]
                    ]
                ]
            ]
        ]


modeSwitch : Model -> Html Msg
modeSwitch model =
    div
        [ class
            ("auth-mode-switch"
                ++ (if model.registrationEnabled then
                        ""

                    else
                        " single"
                   )
            )
        , attribute "role" "group"
        , attribute "aria-label" "Account access"
        ]
        [ modeButton model "login" "Sign in"
        , if model.registrationEnabled then
            modeButton model "register" "Register"

          else
            text ""
        ]


modeButton : Model -> String -> String -> Html Msg
modeButton model mode labelText =
    button
        [ type_ "button"
        , class
            ("auth-mode-btn"
                ++ (if model.authMode == mode then
                        " active"

                    else
                        ""
                   )
            )
        , onClick (AuthMode mode)
        ]
        [ text labelText ]


field : String -> String -> List (Html.Attribute Msg) -> Html Msg
field fieldId labelText attributes =
    div [ class "field" ]
        [ label [ attribute "for" fieldId ] [ text labelText ]
        , input (id fieldId :: attributes) []
        ]


passwordField : Model -> Html Msg
passwordField model =
    div [ class "field" ]
        [ label [ attribute "for" "p" ] [ text "Password" ]
        , div [ class "auth-password-field" ]
            [ input
                [ id "p"
                , type_
                    (if model.authPasswordVisible then
                        "text"

                     else
                        "password"
                    )
                , attribute "autocomplete"
                    (if model.authMode == "login" then
                        "current-password"

                     else
                        "new-password"
                    )
                , maxlength 256
                , value model.authPassword
                , onInput AuthPassword
                ]
                []
            , button
                [ type_ "button"
                , class "auth-password-toggle"
                , onClick ToggleAuthPasswordVisibility
                , attribute "aria-label"
                    (if model.authPasswordVisible then
                        "Hide password"

                     else
                        "Show password"
                    )
                ]
                [ text
                    (if model.authPasswordVisible then
                        "Hide"

                     else
                        "Show"
                    )
                ]
            ]
        ]


validationMessage : Model -> Html Msg
validationMessage model =
    case validationError { model | authBusy = False } of
        Just message ->
            if String.isEmpty model.authUsername && String.isEmpty model.authPassword then
                text ""

            else
                div [ class "auth-error", attribute "role" "alert" ] [ text message ]

        Nothing ->
            text ""


passwordStrength : String -> String
passwordStrength password =
    if String.length password >= 16 then
        "strong"

    else if String.length password >= 10 then
        "medium"

    else
        "weak"


validationError : Model -> Maybe String
validationError model =
    let
        username =
            String.trim model.authUsername

        password =
            model.authPassword
    in
    if model.authBusy then
        Just "Please wait for the current request to finish."

    else if String.length username < 3 then
        Just "Username must be at least 3 characters."

    else if String.length username > 24 then
        Just "Username must be 24 characters or less."

    else if model.authMode == "register" && String.length password < 10 then
        Just "Password must be at least 10 characters."

    else if model.authMode == "register" && model.authPasswordConfirm /= password then
        Just "Passwords do not match."

    else if model.authMode == "login" && String.isEmpty password then
        Just "Enter your password."

    else
        Nothing


ready : Model -> Bool
ready model =
    validationError { model | authBusy = False } == Nothing
