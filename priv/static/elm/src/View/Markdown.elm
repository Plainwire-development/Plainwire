module View.Markdown exposing (body, preview, renderBody)

import Html exposing (Html, a, audio, button, code, div, img, input, pre, span, text, video)
import Html.Attributes exposing (alt, attribute, class, href, preload, rel, src, step, target, title, type_)


body : String -> String -> Html msg
body username source =
    div [ class "msg-body", attribute "data-me" username ] (renderBody source)


preview : String -> Html msg
preview source =
    Html.node "pw-markdown"
        [ attribute "source" source
        , attribute "compact" ""
        ]
        []


renderBody : String -> List (Html msg)
renderBody source =
    renderRichChunks (String.lines source) [] Nothing []


renderRichChunks : List String -> List String -> Maybe String -> List (Html msg) -> List (Html msg)
renderRichChunks remaining pending fence rendered =
    let
        flush =
            if List.isEmpty pending then
                rendered

            else
                markdown (String.join "\n" (List.reverse pending)) :: rendered
    in
    case remaining of
        [] ->
            List.reverse flush

        line :: rest ->
            let
                marker =
                    String.left 3 (String.trimLeft line)

                nextFence =
                    if marker == "```" || marker == "~~~" then
                        if fence == Just marker then
                            Nothing

                        else if fence == Nothing then
                            Just marker

                        else
                            fence

                    else
                        fence
            in
            if fence == Nothing then
                case spoilerAttachmentLine line of
                    Just inner ->
                        renderRichChunks rest [] nextFence (renderSpoilerAttachment inner :: flush)

                    Nothing ->
                        if attachmentMarkup line /= Nothing then
                            renderRichChunks rest [] nextFence (renderAttachment line :: flush)

                        else
                            renderRichChunks rest (line :: pending) nextFence rendered

            else
                renderRichChunks rest (line :: pending) nextFence rendered


markdown : String -> Html msg
markdown source =
    Html.node "pw-markdown" [ attribute "source" source ] []


spoilerAttachmentLine : String -> Maybe String
spoilerAttachmentLine line =
    let
        trimmed =
            String.trim line
    in
    if String.startsWith "||" trimmed && String.endsWith "||" trimmed && String.length trimmed > 4 then
        let
            inner =
                String.dropRight 2 (String.dropLeft 2 trimmed)
        in
        if attachmentMarkup inner /= Nothing then
            Just inner

        else
            Nothing

    else
        Nothing


renderSpoilerAttachment : String -> Html msg
renderSpoilerAttachment inner =
    Html.details [ class "spoiler-attachment" ]
        [ Html.summary [ class "spoiler-attachment-summary" ]
            [ span [ class "spoiler-attachment-icon", attribute "aria-hidden" "true" ] [ text "◐" ]
            , text "Spoiler attachment"
            ]
        , div [ class "spoiler-attachment-content" ] [ renderAttachment inner ]
        ]


renderAttachment : String -> Html msg
renderAttachment line =
    case attachmentMarkup line of
        Just ( AttachmentImage, name, url ) ->
            let
                animated =
                    String.endsWith ".gif" (String.toLower name)

                imageClass =
                    if animated then
                        "message-image animated-image"

                    else
                        "message-image"

                linkClass =
                    if animated then
                        "message-image-link message-gif-link"

                    else
                        "message-image-link"
            in
            a [ class linkClass, href url, target "_blank", rel "noopener" ]
                [ img [ class imageClass, src url, alt name, attribute "loading" "lazy", attribute "decoding" "async" ] [] ]

        Just ( AttachmentAudio, name, url ) ->
            div [ class "media-attachment pw-media-player pw-audio-player", attribute "data-media-url" url ]
                [ audio [ class "pw-audio-element", src url, preload "metadata" ] []
                , button [ type_ "button", class "pw-media-play", attribute "data-media-action" "play", attribute "aria-label" ("Play " ++ name) ] [ text "Play" ]
                , div [ class "pw-media-copy" ]
                    [ div [ class "pw-media-heading" ]
                        [ Html.b [ class "pw-media-name", title name ] [ text name ]
                        , a [ class "pw-media-download", href url, attribute "download" name, title "Download audio" ] [ text "Download" ]
                        ]
                    , div [ class "pw-media-timeline" ]
                        [ span [ class "pw-media-time" ] [ text "0:00" ]
                        , input [ class "pw-media-seek", type_ "range", Html.Attributes.min "0", Html.Attributes.max "1000", step "1", attribute "aria-label" "Seek audio" ] []
                        , span [ class "pw-media-duration" ] [ text "-:--" ]
                        ]
                    ]
                , button [ type_ "button", class "pw-media-mute", attribute "data-media-action" "mute", attribute "aria-label" "Mute audio" ] [ text "Sound" ]
                , input [ class "pw-media-volume", type_ "range", Html.Attributes.min "0", Html.Attributes.max "1", step "0.02", attribute "aria-label" "Audio volume" ] []
                ]

        Just ( AttachmentVideo, name, url ) ->
            div [ class "media-attachment pw-media-player pw-video-player", attribute "data-media-url" url ]
                [ div [ class "pw-video-frame" ]
                    [ video [ class "message-video", src url, preload "metadata", attribute "playsinline" "" ] []
                    , button [ type_ "button", class "pw-video-center-play", attribute "data-media-action" "play", attribute "aria-label" ("Play " ++ name) ] [ text "Play" ]
                    ]
                , div [ class "pw-video-controls" ]
                    [ button [ type_ "button", class "pw-media-play compact", attribute "data-media-action" "play", attribute "aria-label" ("Play " ++ name) ] [ text "Play" ]
                    , span [ class "pw-media-time" ] [ text "0:00" ]
                    , input [ class "pw-media-seek", type_ "range", Html.Attributes.min "0", Html.Attributes.max "1000", step "1", attribute "aria-label" "Seek video" ] []
                    , span [ class "pw-media-duration" ] [ text "-:--" ]
                    , button [ type_ "button", class "pw-media-mute compact", attribute "data-media-action" "mute", attribute "aria-label" "Mute video" ] [ text "Sound" ]
                    , input [ class "pw-media-volume", type_ "range", Html.Attributes.min "0", Html.Attributes.max "1", step "0.02", attribute "aria-label" "Video volume" ] []
                    , button [ type_ "button", class "pw-media-fullscreen", attribute "data-media-action" "fullscreen", attribute "aria-label" "Fullscreen video" ] [ text "Full" ]
                    ]
                , div [ class "pw-video-meta" ]
                    [ span [ title name ] [ text name ]
                    , a [ href url, attribute "download" name, title "Download video" ] [ text "Download" ]
                    ]
                ]

        Just ( AttachmentFile, name, url ) ->
            a [ class "message-file", href url, target "_blank", rel "noopener" ]
                [ span [ class "message-file-icon" ] [ text "↧" ], span [] [ text name ] ]

        Nothing ->
            markdown line


type AttachmentKind
    = AttachmentImage
    | AttachmentAudio
    | AttachmentVideo
    | AttachmentFile


attachmentMarkup : String -> Maybe ( AttachmentKind, String, String )
attachmentMarkup line =
    let
        parse kind prefix endpoint =
            if String.startsWith prefix line && String.endsWith ")" line then
                case String.split ("](" ++ endpoint) line of
                    [ left, idPart ] ->
                        let
                            name =
                                String.dropLeft (String.length prefix) left

                            ident =
                                String.dropRight 1 idPart
                        in
                        if String.isEmpty name || String.isEmpty ident || String.contains "/" ident then
                            Nothing

                        else
                            Just ( kind name, name, endpoint ++ ident )

                    _ ->
                        Nothing

            else
                Nothing

        fileKind name =
            let
                lower =
                    String.toLower name

                has extensions =
                    List.any (\extension -> String.endsWith extension lower) extensions
            in
            if has [ ".mp3", ".wav", ".ogg", ".m4a", ".aac", ".flac", ".opus" ] then
                AttachmentAudio

            else if has [ ".mp4", ".webm", ".mov", ".m4v", ".ogv" ] then
                AttachmentVideo

            else
                AttachmentFile
    in
    case parse (always AttachmentImage) "![" "/api/files/" of
        Just value ->
            Just value

        Nothing ->
            case parse (always AttachmentImage) "![" "/api/media/" of
                Just value ->
                    Just value

                Nothing ->
                    parse fileKind "[" "/api/files/"
