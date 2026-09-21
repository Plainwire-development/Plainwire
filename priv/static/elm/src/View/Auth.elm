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
                    [ h2 [] [ text (heading model) ]
                    , p [ class "muted" ] [ text (subheading model) ]
                    ]
                , if model.authMode == "forgot" || model.authMode == "reset" then
                    text ""

                  else
                    modeSwitch model
                , Html.form [ class "auth-fields", onSubmit (formMsg model) ]
                    (formFields model
                        ++ [ validationMessage model
                           , noticeMessage model
                           , button [ type_ "submit", class "btn auth-submit", disabled (model.authBusy || not (ready model)) ]
                                [ text (submitLabel model) ]
                           ]
                    )
                , extraLinks model
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


heading : Model -> String
heading model =
    case model.authMode of
        "register" ->
            "Create your account"

        "forgot" ->
            "Forgot password"

        "reset" ->
            "Choose a new password"

        _ ->
            "Welcome back"


subheading : Model -> String
subheading model =
    case model.authMode of
        "register" ->
            "Set up an account on this Plainwire instance."

        "forgot" ->
            if model.passwordResetEnabled then
                "Enter your username or the verified email on that account. If a reset is possible, we will email a link."

            else
                "Password reset email is only available on the hosted Plainwire server, and only for accounts with a verified email."

        "reset" ->
            "This link expires quickly. Pick a password at least 10 characters long."

        _ ->
            "Sign in to continue to " ++ model.appName ++ "."


formMsg : Model -> Msg
formMsg model =
    case model.authMode of
        "forgot" ->
            RequestPasswordReset

        "reset" ->
            ResetPassword

        _ ->
            DoAuth


submitLabel : Model -> String
submitLabel model =
    if model.authBusy then
        "Working…"

    else
        case model.authMode of
            "register" ->
                "Create account"

            "forgot" ->
                "Send reset link"

            "reset" ->
                "Update password"

            _ ->
                "Sign in"


formFields : Model -> List (Html Msg)
formFields model =
    case model.authMode of
        "forgot" ->
            [ field "u" "Username or email"
                [ type_ "text"
                , attribute "autocomplete" "username"
                , attribute "autocapitalize" "none"
                , attribute "spellcheck" "false"
                , maxlength 254
                , placeholder "yourname or you@example.com"
                , value model.authUsername
                , onInput AuthUsername
                ]
            ]

        "reset" ->
            [ passwordField model
            , field "pc" "Confirm password"
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
            ]

        _ ->
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
            ]
                ++ (if model.authMode == "register" then
                        [ field "d" "Display name"
                            [ type_ "text"
                            , attribute "autocomplete" "name"
                            , maxlength 48
                            , placeholder "How people see you"
                            , value model.authDisplayName
                            , onInput AuthDisplayName
                            ]
                        , field "e" "Email (optional)"
                            [ type_ "email"
                            , attribute "autocomplete" "email"
                            , maxlength 254
                            , placeholder "you@example.com"
                            , value model.authEmail
                            , onInput AuthEmail
                            ]
                        ]

                    else
                        []
                   )
                ++ [ passwordField model ]
                ++ (if model.authMode == "register" then
                        [ div [ class "auth-password-meter" ]
                            [ div [ class ("auth-password-bar strength-" ++ passwordStrength model.authPassword) ] []
                            , small [ class "muted" ] [ text "Use at least 10 characters. A longer unique passphrase is best." ]
                            ]
                        , field "pc" "Confirm password"
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
                        , small [ class "muted" ] [ text "Email is optional. Password reset only works after that address is verified." ]
                        ]

                    else
                        []
                   )


extraLinks : Model -> Html Msg
extraLinks model =
    div [ class "auth-extra-links" ]
        (case model.authMode of
            "forgot" ->
                [ button [ type_ "button", class "auth-text-link", onClick (AuthMode "login") ] [ text "Back to sign in" ] ]

            "reset" ->
                [ button [ type_ "button", class "auth-text-link", onClick (AuthMode "login") ] [ text "Back to sign in" ]
                , if model.passwordResetEnabled then
                    button [ type_ "button", class "auth-text-link", onClick (AuthMode "forgot") ] [ text "Request a new link" ]

                  else
                    text ""
                ]

            "login" ->
                if model.passwordResetEnabled then
                    [ button [ type_ "button", class "auth-text-link", onClick (AuthMode "forgot") ] [ text "Forgot password?" ] ]

                else
                    []

            _ ->
                []
        )


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
        [ label [ attribute "for" "p" ]
            [ text
                (if model.authMode == "reset" then
                    "New password"

                 else
                    "Password"
                )
            ]
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


noticeMessage : Model -> Html Msg
noticeMessage model =
    if String.isEmpty model.authNotice then
        text ""

    else
        div [ class "auth-notice", attribute "role" "status" ] [ text model.authNotice ]


validationMessage : Model -> Html Msg
validationMessage model =
    case validationError { model | authBusy = False } of
        Just message ->
            if blankForm model then
                text ""

            else
                div [ class "auth-error", attribute "role" "alert" ] [ text message ]

        Nothing ->
            text ""


blankForm : Model -> Bool
blankForm model =
    String.isEmpty model.authUsername
        && String.isEmpty model.authPassword
        && String.isEmpty model.authEmail


passwordStrength : String -> String
passwordStrength password =
    if String.length password >= 16 then
        "strong"

    else if String.length password >= 10 then
        "medium"

    else
        "weak"


looksLikeEmail : String -> Bool
looksLikeEmail value =
    let
        trimmed =
            String.trim value
    in
    String.contains "@" trimmed && String.contains "." trimmed && String.length trimmed >= 6


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

    else if model.authMode == "forgot" then
        if String.length username < 3 then
            Just "Enter a username or email."

        else
            Nothing

    else if model.authMode == "reset" then
        if String.length password < 10 then
            Just "Password must be at least 10 characters."

        else if model.authPasswordConfirm /= password then
            Just "Passwords do not match."

        else if String.length model.authResetToken < 16 then
            Just "This reset link is incomplete. Request a new one from the sign-in page."

        else
            Nothing

    else if String.length username < 3 then
        Just "Username must be at least 3 characters."

    else if String.length username > 24 then
        Just "Username must be 24 characters or less."

    else if model.authMode == "register" && String.length password < 10 then
        Just "Password must be at least 10 characters."

    else if model.authMode == "register" && model.authPasswordConfirm /= password then
        Just "Passwords do not match."

    else if model.authMode == "register" && not (String.isEmpty (String.trim model.authEmail)) && not (looksLikeEmail model.authEmail) then
        Just "Enter a valid email, or leave it blank."

    else if model.authMode == "login" && String.isEmpty password then
        Just "Enter your password."

    else
        Nothing


ready : Model -> Bool
ready model =
    validationError { model | authBusy = False } == Nothing
