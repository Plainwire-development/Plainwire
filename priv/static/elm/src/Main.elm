module Main exposing (main)

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
import View.App exposing (..)
import View.Ui exposing (..)
import View.Auth as Auth
import View.Composer as Composer
import View.Home as Home
import View.Markdown as Markdown
import View.Notifications as Notifications



-- PORTS JS INTEROP


type BridgeTag
    = BtToast String
    | BtSilentSync
    | BtStartCall Int
    | BtAcceptCall Int
    | BtDeclineCall
    | BtEndCall
    | BtJoinVoice Int
    | BtLeaveVoice
    | BtVoiceMute Bool
    | BtVoiceDeafen Bool
    | BtCallSignal Int String
    | BtWsEvent E.Value
    | BtSyncData E.Value
    | BtFileRead String String
    | BtLoadMoreMessages
    | BtHashChange String
    | BtTick


decodeBridge : E.Value -> Msg
decodeBridge val =
    case D.decodeValue bridgeDecoder val of
        Ok msg ->
            msg

        Err _ ->
            NoOp


decodeFileInput : E.Value -> Msg
decodeFileInput val =
    case D.decodeValue (D.map2 FileUpload (D.field "id" D.string) (D.field "data" (D.nullable D.string))) val of
        Ok msg ->
            msg

        Err _ ->
            NoOp


bridgeDecoder : Decoder Msg
bridgeDecoder =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "clear_drafts" ->
                        D.succeed ClearDrafts

                    "attachment_ready" ->
                        D.map2 AttachmentReady (D.field "route" D.string) (D.field "data" D.string)

                    "toast" ->
                        D.map Toast (D.field "data" D.string)

                    "ws_event" ->
                        D.map WsEvent (D.field "data" D.value)

                    "sync_data" ->
                        D.map handleSyncData (D.field "data" D.value)

                    "hash_change" ->
                        D.map SetRoute (D.field "data" D.string)

                    "file_read" ->
                        D.map2 FileUpload (D.field "id" D.string) (D.field "data" (D.nullable D.string))

                    "load_more_messages" ->
                        D.succeed LoadMoreMessages

                    "message_jump_missing" ->
                        D.map JumpToMessage (D.field "data" D.int)

                    "rtc_peer_connected" ->
                        D.map4 SetCallPeerConnected
                            (D.field "room_kind" D.string)
                            (D.field "room_id" D.int)
                            (D.field "user_id" D.int)
                            (D.field "connected" D.bool)

                    "rtc_peer_failed" ->
                        D.map4 SetCallPeerFailed
                            (D.field "room_kind" D.string)
                            (D.field "room_id" D.int)
                            (D.field "user_id" D.int)
                            (D.field "failed" D.bool)

                    "rtc_audio_state" ->
                        D.map2 RtcAudioState
                            (D.field "muted" D.bool)
                            (D.field "deafened" D.bool)

                    "tick" ->
                        D.succeed (Tick (Time.millisToPosix 0))

                    "presence_state" ->
                        D.field "data" D.value |> D.map PresenceState

                    "presence_online" ->
                        D.field "data" (D.map2 PresenceOnline (D.field "user_id" D.int) (D.field "status" D.string))

                    "presence_offline" ->
                        D.map PresenceOffline (D.field "data" D.int)

                    "presence_status" ->
                        D.field "data" (D.map2 PresenceStatus (D.field "user_id" D.int) (D.field "status" D.string))

                    "status_change" ->
                        D.map SetMyStatus (D.field "data" D.string)

                    "screen_share_started" ->
                        D.succeed (BridgeEvent "screen_share_started" E.null)

                    "screen_share_stopped" ->
                        D.succeed (BridgeEvent "screen_share_stopped" E.null)

                    "rtc_join_failed" ->
                        D.map RtcJoinFailed (D.field "data" D.string)

                    "audio_devices" ->
                        D.map AudioDevices (D.field "data" D.value)

                    "mic_test_level" ->
                        D.map MicTestLevel (D.field "data" D.int)

                    "mic_test_failed" ->
                        D.map MicTestFailed (D.field "data" D.string)

                    "ws_status" ->
                        D.map WsStatus (D.field "data" D.bool)

                    "rtc_resuming" ->
                        D.map5 RtcResuming
                            (D.field "room_kind" D.string)
                            (D.field "room_id" D.int)
                            (D.field "muted" D.bool)
                            (D.field "deafened" D.bool)
                            (D.field "muted_before_deafen" D.bool |> defaultValue False)

                    "sound_preference" ->
                        D.map SetSoundPreference (D.field "data" D.bool)

                    "chat_enter_sends" ->
                        D.map SetChatEnterSends (D.field "data" D.bool)

                    "shortcut" ->
                        D.map ShortcutAction (D.field "data" D.string)

                    "link_previews_enabled" ->
                        D.map SetLinkPreviewsEnabled (D.field "data" D.bool)

                    "animated_media_enabled" ->
                        D.map SetAnimatedMediaEnabled (D.field "data" D.bool)

                    "compact_messages" ->
                        D.map SetCompactMessages (D.field "data" D.bool)

                    "media_preload_enabled" ->
                        D.map SetMediaPreloadEnabled (D.field "data" D.bool)

                    "ui_preferences" ->
                        D.map UiPreferences (D.field "data" D.value)

                    _ ->
                        D.succeed NoOp
            )


handleSyncData : E.Value -> Msg
handleSyncData val =
    case D.decodeValue decodeSyncData val of
        Ok d ->
            SilentSync True

        -- will refetch
        Err _ ->
            NoOp



-- MAIN


type alias Flags =
    { appName : String
    , registrationEnabled : Bool
    , passwordResetEnabled : Bool
    , instanceDescription : String
    , defaultTheme : String
    , version : String
    }


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        , onUrlChange = \_ -> NoOp
        , onUrlRequest = \_ -> NoOp
        }



-- INIT


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url _ =
    let
        active =
            parseRoute (Maybe.withDefault "" url.fragment)

        appName =
            if String.isEmpty (String.trim flags.appName) then
                "Plainwire"

            else
                String.left 48 (String.trim flags.appName)

        defaultTheme =
            if List.member flags.defaultTheme [ "system", "light", "dark" ] then
                flags.defaultTheme

            else
                "system"
    in
    ( { appName = appName
      , registrationEnabled = flags.registrationEnabled
      , passwordResetEnabled = flags.passwordResetEnabled
      , instanceDescription = String.left 120 (String.trim flags.instanceDescription)
      , clientVersion = String.left 32 (String.trim flags.version)
      , me = Nothing
      , csrf = ""
      , serverTime = 0
      , timeZone = Time.utc
      , absoluteTimestamps = False
      , forums = []
      , threads = []
      , currentThread = Nothing
      , replies = []
      , servers = []
      , convs = []
      , conversationMembers = Dict.empty
      , friends = []
      , notifs = []
      , searchUsers = []
      , searchThreads = []
      , searchMessages = []
      , availableCommands = []
      , currentServer = Nothing
      , currentProfile = Nothing
      , currentServerProfile = Nothing
      , invitePreview = Nothing
      , msg = []
      , pinnedMessages = []
      , messageContextMode = False
      , nextBefore = Nothing
      , loadingOlderMessages = False
      , hasOlderMessages = True
      , active = active
      , serverCache = Dict.empty
      , drafts = Dict.empty
      , wsConnected = False
      , pageVisible = True
      , isLeader = False
      , tabId = ""
      , subs = Set.empty
      , mentionHints = Set.empty
      , voice =
            { mode = Nothing
            , id = Nothing
            , stream = Nothing
            , peers = Dict.empty
            , failedPeers = Dict.empty
            , users = Dict.empty
            , muted = False
            , deafened = False
            , mutedBeforeDeafen = False
            , screenShare = False
            }
      , callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }
      , activeCalls = Dict.empty
      , callMode = Idle
      , soundEnabled = True
      , chatEnterSends = True
      , linkPreviewsEnabled = True
      , animatedMediaEnabled = True
      , compactMessages = False
      , mediaPreloadEnabled = True
      , uiDensity = "comfortable"
      , uiFontScale = "default"
      , uiAccent = "blue"
      , uiCornerStyle = "default"
      , reduceMotion = False
      , replyTo = Nothing
      , toast = Nothing
      , modal = Nothing
      , settingsSearch = ""
      , settingsTab = "profile"
      , inputText = ""
      , editingMessageId = Nothing
      , editingMessageText = ""
      , sidebarOpen = False
      , serversSheetOpen = False
      , ctxMenu = Nothing
      , threadReply = ""
      , searchQuery = ""
      , authMode =
            if String.startsWith "reset/" (Maybe.withDefault "" url.fragment) then
                "reset"

            else if String.startsWith "forgot" (Maybe.withDefault "" url.fragment) then
                "forgot"

            else
                "login"
      , authUsername = ""
      , authBusy = False
      , authDisplayName = ""
      , authEmail = ""
      , authPassword = ""
      , authPasswordConfirm = ""
      , authPasswordVisible = False
      , authResetToken = authTokenFromFragment (Maybe.withDefault "" url.fragment)
      , authNotice = ""
      , serverName = ""
      , serverDescription = ""
      , booting = True
      , userStatuses = Dict.empty
      , failedMsgIds = Set.empty
      , currentProfileRelationship = "none"
      , currentProfileBlockedByMe = False
      , pendingMessages = Dict.empty
      , outbox = Dict.empty
      , nextMessageId = -1
      , profileDisplayName = ""
      , profileBio = ""
      , profileAvatarUrl = ""
      , profileBannerUrl = ""
      , profileAvatarPreviewUrl = ""
      , profileBannerPreviewUrl = ""
      , profileAvatarUploading = False
      , profileBannerUploading = False
      , profileStatus = "online"
      , profileTheme = defaultTheme
      , modalTitle = ""
      , modalBody = ""
      , modalPeopleQuery = ""
      , modalUserIds = ""
      , modalBannerUrl = ""
      , modalWelcome = ""
      , modalAccentColor = "#5865f2"
      , friendsTab = "online"
      , friendQuery = ""
      , friendSearchAttempted = False
      , pendingConversationId = Nothing
      , collapsedCategories = Set.empty
      , audioInputs = []
      , audioOutputs = []
      , selectedAudioInput = ""
      , selectedAudioOutput = ""
      , outputSelectionSupported = False
      , voiceProcessingMode = "noise"
      , krispAvailable = False
      , micTesting = False
      , micTestLevel = 0
      , micMonitoring = False
      , entryReadId = Nothing
      , entryReadCaptured = False
      }
    , Cmd.batch
        (apiSend (encodeApiRequest (ApiGet "/me"))
            :: requestNotifyPermission True
            :: Task.perform GotTimeZone Time.here
            :: (case verifyTokenFromFragment (Maybe.withDefault "" url.fragment) of
                    Just token ->
                        [ apiSend
                            (encodeApiRequest
                                (ApiPost "/email/verify" (Just (E.object [ ( "token", E.string token ) ])))
                            )
                        ]

                    Nothing ->
                        []
               )
        )
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        SetRoute hash ->
            let
                route =
                    String.dropLeft 1 hash

                active =
                    parseRoute route

                clearedInvite =
                    case active of
                        InviteView _ ->
                            Nothing

                        _ ->
                            model.invitePreview

                clearedThread =
                    case active of
                        ThreadView _ ->
                            Nothing

                        _ ->
                            model.currentThread

                clearMessages =
                    case ( model.active, active ) of
                        ( DmView a, DmView b ) ->
                            a /= b

                        ( ChannelView a, ChannelView b ) ->
                            a /= b

                        ( _, _ ) ->
                            model.active /= active

                pendingId =
                    case active of
                        DmView id ->
                            if model.pendingConversationId == Just id then
                                model.pendingConversationId

                            else
                                Nothing

                        _ ->
                            Nothing
            in
            ( { model
                | active = active
                , msg =
                    if clearMessages then
                        Dict.values model.outbox |> List.filter (messageApplies active) |> List.sortBy .createdAt

                    else
                        model.msg
                , inputText =
                    if clearMessages then
                        Dict.get (draftKeyFor active) model.drafts |> Maybe.withDefault ""

                    else
                        model.inputText
                , replyTo =
                    if clearMessages then
                        Nothing

                    else
                        model.replyTo
                , pinnedMessages =
                    if clearMessages then
                        []

                    else
                        model.pinnedMessages
                , messageContextMode =
                    if clearMessages then
                        False

                    else
                        model.messageContextMode
                , sidebarOpen = False
                , serversSheetOpen = False
                , invitePreview = clearedInvite
                , currentThread = clearedThread
                , nextBefore = Nothing
                , loadingOlderMessages = False
                , hasOlderMessages =
                    if clearMessages then
                        True

                    else
                        model.hasOlderMessages
                , pendingConversationId = pendingId
                , availableCommands =
                    case active of
                        ChannelView _ ->
                            if clearMessages then
                                []

                            else
                                model.availableCommands

                        _ ->
                            []
                , mentionHints =
                    case active of
                        DmView id ->
                            Set.remove ("dm:" ++ String.fromInt id) model.mentionHints

                        ChannelView id ->
                            Set.remove ("channel:" ++ String.fromInt id) model.mentionHints

                        _ ->
                            model.mentionHints
                , notifs =
                    dismissRouteNotifications active model.notifs
                , entryReadId =
                    case ( model.active, active ) of
                        ( DmView current, DmView id ) ->
                            if current == id then
                                model.entryReadId

                            else
                                Nothing

                        _ ->
                            Nothing
                , entryReadCaptured =
                    case ( model.active, active ) of
                        ( DmView current, DmView id ) ->
                            current == id && model.entryReadCaptured

                        _ ->
                            False
                , authMode =
                    if model.me /= Nothing then
                        model.authMode

                    else if String.startsWith "reset/" route then
                        "reset"

                    else if route == "forgot" then
                        "forgot"

                    else
                        model.authMode
                , authResetToken =
                    if String.startsWith "reset/" route then
                        String.dropLeft 6 route

                    else
                        model.authResetToken
              }
            , Cmd.batch
                ([ bridgeSend
                    (E.object
                        [ ( "tag", E.string "clear_subs" )
                        , ( "data", E.null )
                        ]
                    )
                 , routeCmd active
                 , routeSubCmd active
                 ]
                    ++ (case verifyTokenFromFragment route of
                            Just token ->
                                [ apiSend
                                    (encodeApiRequest
                                        (ApiPost "/email/verify" (Just (E.object [ ( "token", E.string token ) ])))
                                    )
                                ]

                            Nothing ->
                                []
                       )
                )
            )

        AuthMode m ->
            ( { model | authMode = m, authPasswordConfirm = "", authPasswordVisible = False, authNotice = "", toast = Nothing }, Cmd.none )

        AuthUsername s ->
            ( { model | authUsername = s }, Cmd.none )

        AuthDisplayName s ->
            ( { model | authDisplayName = s }, Cmd.none )

        AuthEmail s ->
            ( { model | authEmail = s }, Cmd.none )

        AuthPassword s ->
            ( { model | authPassword = s }, Cmd.none )

        AuthPasswordConfirm s ->
            ( { model | authPasswordConfirm = s }, Cmd.none )

        ToggleAuthPasswordVisibility ->
            ( { model | authPasswordVisible = not model.authPasswordVisible }, Cmd.none )

        ServerName s ->
            ( { model | serverName = s }, Cmd.none )

        ServerDescription s ->
            ( { model | serverDescription = s }, Cmd.none )

        DoAuth ->
            let
                authError =
                    Auth.validationError model

                path =
                    if model.authMode == "login" then
                        "/login"

                    else
                        "/register"

                body =
                    E.object
                        [ ( "username", E.string (String.trim model.authUsername) )
                        , ( "display_name"
                          , E.string
                                (if String.isEmpty (String.trim model.authDisplayName) then
                                    String.trim model.authUsername

                                 else
                                    String.trim model.authDisplayName
                                )
                          )
                        , ( "password", E.string model.authPassword )
                        , ( "email", E.string (String.trim model.authEmail) )
                        ]
                        |> Just
            in
            case authError of
                Just err ->
                    ( { model | toast = Just err }, Cmd.none )

                Nothing ->
                    ( { model | authBusy = True, toast = Nothing, authNotice = "" }, apiSend (encodeApiRequest (ApiPost path body)) )

        RequestPasswordReset ->
            if String.length (String.trim model.authUsername) < 3 then
                ( { model | toast = Just "Enter the username or email for that account." }, Cmd.none )

            else
                ( { model | authBusy = True, toast = Nothing, authNotice = "" }
                , apiSend
                    (encodeApiRequest
                        (ApiPost "/password/forgot"
                            (Just (E.object [ ( "username", E.string (String.trim model.authUsername) ) ]))
                        )
                    )
                )

        ResetPassword ->
            if String.length model.authPassword < 10 then
                ( { model | toast = Just "Password must be at least 10 characters." }, Cmd.none )

            else if model.authPassword /= model.authPasswordConfirm then
                ( { model | toast = Just "Passwords do not match." }, Cmd.none )

            else if String.length model.authResetToken < 16 then
                ( { model | toast = Just "This reset link is missing or incomplete. Request a new one." }, Cmd.none )

            else
                ( { model | authBusy = True, toast = Nothing, authNotice = "" }
                , apiSend
                    (encodeApiRequest
                        (ApiPost "/password/reset"
                            (Just
                                (E.object
                                    [ ( "token", E.string model.authResetToken )
                                    , ( "password", E.string model.authPassword )
                                    ]
                                )
                            )
                        )
                    )
                )

        ApiSuccess tag method requestId val ->
            case ( tag, method ) of
                ( "/me", _ ) ->
                    handleMe val model

                ( "/login", _ ) ->
                    handleMe val model

                ( "/register", _ ) ->
                    handleMe val model

                ( "/password/forgot", _ ) ->
                    ( { model
                        | authBusy = False
                        , authNotice = "If that account has a verified email, we sent a reset link. Check your inbox."
                        , toast = Nothing
                      }
                    , Cmd.none
                    )

                ( "/password/reset", _ ) ->
                    ( { model
                        | authBusy = False
                        , authMode = "login"
                        , authPassword = ""
                        , authPasswordConfirm = ""
                        , authResetToken = ""
                        , authNotice = "Password updated. Sign in with your new password."
                        , toast = Nothing
                      }
                    , setHash "#"
                    )

                ( "/email/verify", _ ) ->
                    ( { model
                        | authBusy = False
                        , authNotice = "Email verified. You can use it to reset your password."
                        , toast = Just "Email verified."
                      }
                    , Cmd.batch
                        [ setHash "#"
                        , if model.me == Nothing then
                            Cmd.none

                          else
                            apiSend (encodeApiRequest (ApiGet "/me"))
                        ]
                    )

                ( "/sync?since=0", _ ) ->
                    handleSync val model

                ( "/friends", "GET" ) ->
                    handleList (D.list (D.maybe decodeFriend) |> D.map (List.filterMap identity)) (\items m -> { m | friends = items }) val model

                ( "/servers", "GET" ) ->
                    handleList (D.list (D.maybe decodeServer) |> D.map (List.filterMap identity)) (\items m -> { m | servers = items }) val model

                ( "/notifications", "GET" ) ->
                    handleList (D.list (D.maybe decodeNotification) |> D.map (List.filterMap identity)) (\items m -> { m | notifs = items }) val model

                ( "/conversations", "GET" ) ->
                    handleList
                        (D.list (D.maybe decodeConversation) |> D.map (List.filterMap identity))
                        (\items m -> { m | convs = sortConvs (mergeConversationDetails m.convs items) })
                        val
                        model

                ( "/forums", "GET" ) ->
                    handleList (D.list decodeForum) (\items m -> { m | forums = items }) val model

                ( "/forums", _ ) ->
                    handleCreateForum val model

                ( "/logout", _ ) ->
                    ( model, bridgeSend (E.object [ ( "tag", E.string "reload" ), ( "data", E.null ) ]) )

                ( "/profile", _ ) ->
                    ( { model | toast = Just "Profile saved" }, apiSend (encodeApiRequest (ApiGet "/me")) )

                ( "/profile/theme", _ ) ->
                    ( model, Cmd.none )

                ( "/notifications/seen", _ ) ->
                    ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                ( "/notifications/clear", _ ) ->
                    ( { model | notifs = [], toast = Just "Notifications cleared" }, Cmd.none )

                ( "/friends/request", _ ) ->
                    ( { model | toast = Just "Friend request sent" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                ( "/friends/accept", _ ) ->
                    ( { model | toast = Just "Friend added" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                ( "/friends/remove", _ ) ->
                    ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                ( "/friends/block", _ ) ->
                    ( { model | currentProfileRelationship = "blocked", currentProfileBlockedByMe = True, toast = Just "User blocked" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                ( "/friends/unblock", _ ) ->
                    ( { model | currentProfileRelationship = "none", currentProfileBlockedByMe = False, toast = Just "User unblocked" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                ( "/conversations", _ ) ->
                    handleCreateConversation val model

                ( "/threads", _ ) ->
                    handleCreateThread val model

                ( _, _ ) ->
                    if String.startsWith "/threads?forum_id=" tag then
                        handleList (D.list decodeThread) (\items m -> { m | threads = items }) val model

                    else if String.startsWith "/thread/" tag && String.endsWith "/vote" tag then
                        handleThreadVote val model

                    else if String.startsWith "/forum/" tag && (String.endsWith "/join" tag || String.endsWith "/leave" tag) then
                        ( model
                        , Cmd.batch
                            [ apiSend (encodeApiRequest (ApiGet "/forums"))
                            , routeCmd model.active
                            ]
                        )

                    else if String.startsWith "/thread/" tag && String.endsWith "/replies" tag then
                        handleReplyCreated val model

                    else if String.startsWith "/server/" tag && String.contains "/member/" tag && String.endsWith "/profile" tag && method == "GET" then
                        handleServerProfile val model

                    else if String.startsWith "/server/" tag && String.endsWith "/delete" tag && method == "POST" then
                        handleServerDeleted val model

                    else if String.startsWith "/message/" tag && String.endsWith "/reactions" tag && method == "POST" then
                        handleReactionChange val model

                    else if String.startsWith "/message/" tag && String.endsWith "/context" tag && method == "GET" then
                        case D.decodeValue
                            (D.map4 (\targetId scope scopeId messages -> { targetId = targetId, scope = scope, scopeId = scopeId, messages = messages })
                                (D.field "target_id" D.int)
                                (D.field "scope" D.string)
                                (D.field "scope_id" D.int)
                                (D.field "messages" (D.list decodeMessage))
                            )
                            val of
                            Ok { targetId, scope, scopeId, messages } ->
                                let
                                    applies =
                                        case model.active of
                                            ChannelView id ->
                                                scope == "channel" && scopeId == id

                                            DmView id ->
                                                scope == "direct" && scopeId == id

                                            _ ->
                                                False
                                in
                                if applies then
                                    ( { model
                                        | msg = messages
                                        , messageContextMode = True
                                        , loadingOlderMessages = False
                                        , hasOlderMessages = True
                                      }
                                    , bridgeSend (E.object [ ( "tag", E.string "jump_to_message" ), ( "data", E.int targetId ) ])
                                    )

                                else
                                    ( model, Cmd.none )

                            Err _ ->
                                ( { model | toast = Just "That replied-to message could not be loaded." }, Cmd.none )

                    else if String.startsWith "/channel/" tag && String.endsWith "/pins" tag && method == "GET" then
                        case D.decodeValue (D.list decodeMessage) val of
                            Ok items ->
                                ( { model | pinnedMessages = items }, Cmd.none )

                            Err _ ->
                                ( { model | pinnedMessages = [], toast = Just "Pinned messages could not be loaded." }, Cmd.none )

                    else if String.startsWith "/message/" tag && String.endsWith "/pin" tag && method == "POST" then
                        case D.decodeValue (D.map2 Tuple.pair (D.field "message_id" D.int) (D.field "pinned" D.bool)) val of
                            Ok ( messageId, pinned ) ->
                                let
                                    updatePinned message =
                                        if message.id == messageId then
                                            { message | pinned = pinned }

                                        else
                                            message

                                    maybeMessage =
                                        findMessage messageId model.msg |> Maybe.map updatePinned

                                    nextPins =
                                        if pinned then
                                            case maybeMessage of
                                                Just message ->
                                                    message :: List.filter (\item -> item.id /= messageId) model.pinnedMessages

                                                Nothing ->
                                                    model.pinnedMessages

                                        else
                                            List.filter (\item -> item.id /= messageId) model.pinnedMessages
                                in
                                ( { model
                                    | msg = List.map updatePinned model.msg
                                    , pinnedMessages = nextPins
                                    , toast = Just (if pinned then "Message pinned" else "Message unpinned")
                                  }
                                , Cmd.none
                                )

                            Err _ ->
                                ( model, Cmd.none )

                    else if String.startsWith "/server/" tag && method == "POST" && String.contains "/categor" tag then
                        ( { model
                            | toast =
                                Just
                                    (if String.endsWith "/delete" tag then
                                        "Category deleted"

                                     else if String.contains "/category/" tag then
                                        "Category saved"

                                     else
                                        "Category created"
                                    )
                          }
                        , Cmd.batch [ refreshCurrentServer model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) ]
                        )

                    else if String.startsWith "/channel/" tag && String.endsWith "/move" tag then
                        ( { model | toast = Just "Channel moved" }, refreshCurrentServer model )

                    else if String.endsWith "/delete" tag then
                        ( model, Cmd.none )

                    else if String.startsWith "/thread/" tag then
                        handleThread val model

                    else if String.startsWith "/messages?" tag then
                        handleMessages tag val model

                    else if String.startsWith "/edit_message/" tag then
                        handleMessageUpdatedValue val { model | editingMessageId = Nothing, editingMessageText = "", toast = Just "Message edited" }

                    else if String.startsWith "/forward_message/" tag then
                        ( { model | toast = Just "Message forwarded" }, Cmd.none )

                    else if String.startsWith "/channels/" tag && String.endsWith "/messages" tag then
                        handleMessageSent requestId val model

                    else if String.startsWith "/conversation/" tag && String.endsWith "/messages" tag then
                        handleMessageSent requestId val model

                    else if String.startsWith "/conversation/" tag && String.endsWith "/read" tag then
                        ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                    else if String.startsWith "/conversation/" tag && String.endsWith "/leave" tag then
                        ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                    else if String.startsWith "/conversation/" tag && String.endsWith "/members" tag then
                        ( { model | toast = Just "People added" }
                        , Cmd.batch
                            [ apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                            , apiSend (encodeApiRequest (ApiGet (String.dropRight 8 tag)))
                            ]
                        )

                    else if String.startsWith "/conversation/" tag && method == "GET" then
                        handleConversationDetail val model

                    else if String.startsWith "/conversation/" tag then
                        ( { model | toast = Just "Conversation updated" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )

                    else if String.startsWith "/users?q=" tag then
                        handleList (D.list decodeUser) (\items m -> { m | searchUsers = items }) val model

                    else if String.startsWith "/threads?q=" tag then
                        handleList (D.list decodeThread) (\items m -> { m | searchThreads = items }) val model

                    else if String.startsWith "/search/messages?q=" tag then
                        case D.decodeValue (D.field "messages" (D.list decodeMessage)) val of
                            Ok items ->
                                ( { model | searchMessages = items }, Cmd.none )

                            Err _ ->
                                ( { model | searchMessages = [], toast = Just "Message search could not be loaded." }, Cmd.none )

                    else if String.startsWith "/commands?channel_id=" tag then
                        handleList (D.list decodeBotCommand) (\items m -> { m | availableCommands = items }) val model

                    else if String.startsWith "/commands/" tag && String.endsWith "/invoke" tag then
                        handleMessageSent Nothing (fromApiField "message" val) { model | inputText = "", replyTo = Nothing, drafts = Dict.remove (draftKeyFor model.active) model.drafts }

                    else if String.startsWith "/server/" tag && String.endsWith "/channels" tag then
                        ( { model | toast = Just "Channel created" }, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), routeCmd model.active ] )

                    else if String.startsWith "/server/" tag && String.endsWith "/wires" tag then
                        handleInviteCreated val model

                    else if String.startsWith "/server/" tag then
                        handleServerData val model

                    else if String.startsWith "/profile/" tag then
                        handleProfile val model

                    else if String.startsWith "/wires/" tag && String.endsWith "/join" tag then
                        handleInviteJoin val model

                    else if String.startsWith "/wires/" tag then
                        handleInvitePreview val model

                    else if tag == "/servers" then
                        handleCreateServer val model

                    else
                        ( model, Cmd.none )

        ApiError tag method requestId err ->
            if String.startsWith "/wires/" tag && not (String.endsWith "/join" tag) then
                ( { model | invitePreview = Nothing, toast = Just (fmtErr err), modal = Just "join_invite", modalUserIds = "" }, setHash "#" )

            else if String.startsWith "/users?q=" tag then
                ( { model | friendSearchAttempted = False, toast = Just "Search is temporarily unavailable. Please try again." }, Cmd.none )

            else if method == "GET" && List.member tag [ "/friends", "/servers", "/notifications", "/conversations" ] then
                -- These list endpoints are refreshed independently by the bridge when
                -- bootstrap sync degrades. Keep the last known-good model and avoid a
                -- duplicate error toast; prolonged recovery is surfaced once by the
                -- bridge with a calm connection-status message.
                ( model, Cmd.none )

            else if err == "not_authenticated" then
                -- The bridge performs a one-shot reload for an expired authenticated
                -- session. Do not flash a generic request error while that transition
                -- is already in progress; /me will render the signed-out shell.
                ( { model | booting = False, authBusy = False }, Cmd.none )

            else
                let
                    pendingPairs =
                        Dict.toList model.pendingMessages

                    failedPairs =
                        List.filter (\( mid, path ) -> path == tag && requestId == Just mid) pendingPairs

                    ( model2, reconcile ) =
                        case failedPairs of
                            ( msgId, _ ) :: _ ->
                                -- A timed-out POST may already be stored. Reload the
                                -- timeline before the user can retry, so the real
                                -- message replaces the optimistic row instead of a
                                -- second send creating a duplicate.
                                ( { model | failedMsgIds = Set.insert msgId model.failedMsgIds, pendingMessages = Dict.remove msgId model.pendingMessages }
                                , case findMessage msgId model.msg of
                                    Just failedMessage ->
                                        apiSend (encodeApiRequest (ApiGet (timelinePath failedMessage)))

                                    Nothing ->
                                        Cmd.none
                                )

                            [] ->
                                ( model, Cmd.none )
                in
                ( { model2
                    | booting = False
                    , authBusy = False
                    , loadingOlderMessages =
                        if String.startsWith "/messages?" tag then
                            False

                        else
                            model2.loadingOlderMessages
                    , toast = Just (fmtErr err)
                  }
                , reconcile
                )

        WsEvent val ->
            handleWsEvent val model

        Go hash ->
            ( model, setHash hash )

        ToggleSidebar ->
            ( { model | sidebarOpen = not model.sidebarOpen }, Cmd.none )

        CloseSidebar ->
            ( { model | sidebarOpen = False }, Cmd.none )

        ToggleServersSheet ->
            ( { model | serversSheetOpen = not model.serversSheetOpen }, Cmd.none )

        CloseServersSheet ->
            ( { model | serversSheetOpen = False }, Cmd.none )

        Toast s ->
            ( { model | toast = Just s }, Process.sleep 4000 |> Task.perform (\_ -> DismissToast) )

        DismissToast ->
            ( { model | toast = Nothing }, Cmd.none )

        GotTimeZone zone ->
            ( { model | timeZone = zone }, Cmd.none )

        ToggleTimestampMode ->
            ( { model | absoluteTimestamps = not model.absoluteTimestamps }, Cmd.none )

        CloseModal ->
            ( { model | modal = Nothing, currentServerProfile = Nothing }, Cmd.none )

        ClearDrafts ->
            ( { model | drafts = Dict.empty, inputText = "" }, Cmd.none )

        AttachmentReady route markup ->
            let
                key =
                    draftKeyFor (parseRoute (String.dropLeft 1 route))

                previous =
                    Dict.get key model.drafts |> Maybe.withDefault ""

                draft =
                    previous
                        ++ (if previous == "" then
                                ""

                            else
                                "\n"
                           )
                        ++ markup
            in
            ( { model | drafts = Dict.insert key draft model.drafts, toast = Just "Upload added to the original conversation's draft." }, Cmd.none )

        ToggleLastAttachmentSpoiler ->
            case toggleLastAttachmentSpoiler model.inputText of
                Just next ->
                    ( { model | inputText = next, drafts = Dict.insert (draftKeyFor model.active) next model.drafts }, Cmd.none )

                Nothing ->
                    ( { model | toast = Just "Attach a file first, then mark it as a spoiler." }, Cmd.none )

        InputText s ->
            ( { model | inputText = s, drafts = Dict.insert (draftKeyFor model.active) s model.drafts }, Cmd.none )

        SendMessage ->
            sendMessage model

        StartEditMessage m ->
            if m.id > 0 && Maybe.map .id model.me == Just m.userId && m.forwardedFrom == Nothing then
                ( { model | editingMessageId = Just m.id, editingMessageText = m.body, ctxMenu = Nothing }, Cmd.none )

            else
                ( model, Cmd.none )

        EditMessageText body ->
            ( { model | editingMessageText = String.left 5000 body }, Cmd.none )

        CancelEditMessage ->
            ( { model | editingMessageId = Nothing, editingMessageText = "" }, Cmd.none )

        SaveEditMessage mid ->
            let
                body =
                    String.trim model.editingMessageText
            in
            if model.editingMessageId /= Just mid then
                ( model, Cmd.none )

            else if String.isEmpty body then
                ( { model | toast = Just "A message cannot be empty." }, Cmd.none )

            else
                ( { model | ctxMenu = Nothing }
                , apiSend (encodeApiRequest (ApiPost ("/edit_message/" ++ String.fromInt mid) (Just (E.object [ ( "body", E.string body ) ]))))
                )

        InsertComposerText value ->
            ( { model | modal = Nothing }
            , bridgeSend
                (E.object
                    [ ( "tag", E.string "insert_composer_text" )
                    , ( "data", E.string value )
                    ]
                )
            )

        OpenForwardModal m ->
            if m.id > 0 then
                ( { model | modal = Just ("forward_message:" ++ String.fromInt m.id), modalTitle = "", modalBody = "", ctxMenu = Nothing }, Cmd.none )

            else
                ( model, Cmd.none )

        ForwardMessage mid targetScope targetId ->
            if targetId <= 0 || not (List.member targetScope [ "direct", "channel" ]) then
                ( { model | toast = Just "That forwarding destination is unavailable." }, Cmd.none )

            else
                ( { model | modal = Nothing }
                , apiSend
                    (encodeApiRequest
                        (ApiPost ("/forward_message/" ++ String.fromInt mid)
                            (Just
                                (E.object
                                    [ ( "target_scope", E.string targetScope )
                                    , ( "target_id", E.int targetId )
                                    ]
                                )
                            )
                        )
                    )
                )

        SetReplyTo m ->
            ( { model
                | replyTo =
                    Just
                        { id = m.id
                        , userId = m.userId
                        , displayName = m.displayName
                        , body = m.body
                        }
              }
            , Cmd.none
            )

        JumpToMessage mid ->
            if mid <= 0 then
                ( model, Cmd.none )

            else
                case findMessage mid model.msg of
                    Just _ ->
                        ( { model | modal = Nothing, ctxMenu = Nothing }
                        , bridgeSend (E.object [ ( "tag", E.string "jump_to_message" ), ( "data", E.int mid ) ])
                        )

                    Nothing ->
                        ( { model | modal = Nothing, ctxMenu = Nothing }
                        , apiSend (encodeApiRequest (ApiGet ("/message/" ++ String.fromInt mid ++ "/context")))
                        )

        OpenPinnedMessages channelId ->
            if channelId <= 0 then
                ( model, Cmd.none )

            else
                ( { model | modal = Just ("pinned_messages:" ++ String.fromInt channelId), pinnedMessages = [] }
                , apiSend (encodeApiRequest (ApiGet ("/channel/" ++ String.fromInt channelId ++ "/pins")))
                )

        SetMessagePinned message pinned ->
            if message.id <= 0 || message.scope /= "channel" then
                ( model, Cmd.none )

            else
                ( { model | ctxMenu = Nothing }
                , apiSend
                    (encodeApiRequest
                        (ApiPost ("/message/" ++ String.fromInt message.id ++ "/pin")
                            (Just (E.object [ ( "pinned", E.bool pinned ) ]))
                        )
                    )
                )

        ReturnToLatestMessages ->
            ( { model
                | messageContextMode = False
                , msg = Dict.values model.outbox |> List.filter (messageApplies model.active) |> List.sortBy .createdAt
                , hasOlderMessages = True
              }
            , routeCmd model.active
            )

        CancelReply ->
            ( { model | replyTo = Nothing }, Cmd.none )

        VoteThread threadId value ->
            ( model
            , apiSend (encodeApiRequest (ApiPost ("/thread/" ++ String.fromInt threadId ++ "/vote") (Just (E.object [ ( "value", E.int value ) ]))))
            )

        DeleteMessage mid ->
            ( { model | ctxMenu = Nothing }, apiSend (encodeApiRequest (ApiPost ("/delete_message/" ++ String.fromInt mid) (Just (E.object [])))) )

        ToggleReaction mid emoji ->
            if mid <= 0 then
                ( model, Cmd.none )

            else
                ( { model | ctxMenu = Nothing, modal = Nothing }
                , apiSend
                    (encodeApiRequest
                        (ApiPost ("/message/" ++ String.fromInt mid ++ "/reactions")
                            (Just (E.object [ ( "emoji", E.string emoji ) ]))
                        )
                    )
                )

        OpenReactionPicker mid ->
            if mid <= 0 then
                ( model, Cmd.none )

            else
                ( { model | modal = Just ("reaction_picker:" ++ String.fromInt mid), ctxMenu = Nothing }, Cmd.none )

        LeaveConversation cid ->
            ( { model | ctxMenu = Nothing }, Cmd.batch [ apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/leave") (Just (E.object [])))), setHash "#dms" ] )

        CloseConversation cid ->
            ( { model | ctxMenu = Nothing }, Cmd.batch [ apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/close") (Just (E.object [])))), setHash "#dms" ] )

        RetryMessage msgId ->
            case findMessage msgId model.msg of
                Just m ->
                    let
                        path =
                            case m.scope of
                                "direct" ->
                                    "/conversation/" ++ String.fromInt m.scopeId ++ "/messages"

                                "channel" ->
                                    "/channels/" ++ String.fromInt m.scopeId ++ "/messages"

                                _ ->
                                    ""

                        payload =
                            encodeMessage { body = m.body, replyToId = m.replyToId }
                    in
                    if String.isEmpty path then
                        ( model, Cmd.none )

                    else
                        ( { model | failedMsgIds = Set.remove msgId model.failedMsgIds, pendingMessages = Dict.insert msgId path model.pendingMessages }
                        , apiSend (messageRequest msgId path payload)
                        )

                Nothing ->
                    ( model, Cmd.none )

        DismissFailedMessage msgId ->
            ( { model | failedMsgIds = Set.remove msgId model.failedMsgIds, outbox = Dict.remove msgId model.outbox, msg = List.filter (\m -> m.id /= msgId) model.msg }, Cmd.none )

        MarkConvRead cid ->
            ( model, apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/read") (Just (E.object [])))) )

        OpenMessageCtx m x y ->
            ( { model | ctxMenu = Just (messageContext model m x y) }, Cmd.none )

        OpenConvCtx c x y ->
            ( { model | ctxMenu = Just (conversationContext model c x y) }, Cmd.none )

        OpenUserCtx user x y ->
            ( { model | ctxMenu = Just (userContext model user x y) }, Cmd.none )

        OpenServerCtx server x y ->
            ( { model | ctxMenu = Just (serverContext server x y) }, Cmd.none )

        OpenServerMemberCtx serverId member x y ->
            ( { model | ctxMenu = Just (serverMemberContext serverId member x y) }, Cmd.none )

        OpenChannelCtx channel x y ->
            ( { model | ctxMenu = Just (channelContext channel x y) }, Cmd.none )

        CopyText s ->
            ( { model | ctxMenu = Nothing }, copyText s )

        SilentSync _ ->
            ( model
            , if model.me == Nothing then
                Cmd.none

              else
                apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
            )

        Tick now ->
            ( { model | serverTime = Time.posixToMillis now }, Cmd.none )

        WsStatus connected ->
            ( { model | wsConnected = connected }
            , if connected && not model.wsConnected && model.me /= Nothing then
                Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), routeCmd model.active, routeSubCmd model.active ]

              else
                Cmd.none
            )

        PageVisibility visible ->
            ( { model | pageVisible = visible }
            , if visible && model.me /= Nothing then
                Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), routeCmd model.active ]

              else
                Cmd.none
            )

        RtcResuming roomKind roomId muted deafened mutedBeforeDeafen ->
            let
                voiceBase =
                    updateVoiceMode roomKind roomId model.voice

                resumedVoice =
                    { voiceBase | muted = muted, deafened = deafened, mutedBeforeDeafen = mutedBeforeDeafen }
            in
            if roomKind == "call" then
                let
                    active =
                        Dict.get roomId model.activeCalls
                            |> Maybe.withDefault
                                { conversationId = roomId, users = [], startTime = model.serverTime, expanded = False }
                in
                ( { model
                    | voice = resumedVoice
                    , callMode = Connected
                    , activeCalls = Dict.insert roomId active model.activeCalls
                    , callUI = { incoming = Nothing, outgoing = Nothing, active = Just active }
                  }
                , Cmd.none
                )

            else
                ( { model | voice = resumedVoice, callMode = InCall }, Cmd.none )

        ToggleSound ->
            let
                enabled =
                    not model.soundEnabled
            in
            ( { model | soundEnabled = enabled }
            , Cmd.batch
                [ bridgeSend (E.object [ ( "tag", E.string "set_sound_preference" ), ( "data", E.bool enabled ) ])
                , if enabled then
                    playNotification True

                  else
                    Cmd.none
                ]
            )

        SetSoundPreference enabled ->
            ( { model | soundEnabled = enabled }, Cmd.none )

        SetChatEnterSends enabled ->
            ( { model | chatEnterSends = enabled }
            , bridgeSend
                (E.object
                    [ ( "tag", E.string "chat_enter_mode" )
                    , ( "data"
                      , E.string
                            (if enabled then
                                "send"

                             else
                                "newline"
                            )
                      )
                    ]
                )
            )

        SetLinkPreviewsEnabled enabled ->
            ( { model | linkPreviewsEnabled = enabled }
            , bridgeSend (E.object [ ( "tag", E.string "chat_set_link_previews" ), ( "data", E.bool enabled ) ])
            )

        SetAnimatedMediaEnabled enabled ->
            ( { model | animatedMediaEnabled = enabled }
            , bridgeSend (E.object [ ( "tag", E.string "chat_set_animated_media" ), ( "data", E.bool enabled ) ])
            )

        SetCompactMessages enabled ->
            ( { model | compactMessages = enabled }
            , bridgeSend (E.object [ ( "tag", E.string "chat_set_compact_messages" ), ( "data", E.bool enabled ) ])
            )

        SetMediaPreloadEnabled enabled ->
            ( { model | mediaPreloadEnabled = enabled }
            , bridgeSend (E.object [ ( "tag", E.string "privacy_set_media_preload" ), ( "data", E.bool enabled ) ])
            )

        UiPreferences value ->
            let
                stringField name fallback =
                    D.decodeValue (D.field name D.string) value |> Result.withDefault fallback

                boolField name fallback =
                    D.decodeValue (D.field name D.bool) value |> Result.withDefault fallback
            in
            ( { model
                | uiDensity = stringField "density" model.uiDensity
                , uiFontScale = stringField "font_scale" model.uiFontScale
                , uiAccent = stringField "accent" model.uiAccent
                , uiCornerStyle = stringField "corner_style" model.uiCornerStyle
                , reduceMotion = boolField "reduce_motion" model.reduceMotion
              }
            , Cmd.none
            )

        Logout ->
            ( model, apiSend (encodeApiRequest (ApiPost "/logout" (Just (E.object [])))) )

        SettingsSearch query ->
            ( { model | settingsSearch = query }, Cmd.none )

        SetSettingsTab t ->
            ( { model
                | settingsTab = t
                , settingsSearch = ""
                , micTesting =
                    if t == "voice" then
                        model.micTesting

                    else
                        False
                , micTestLevel =
                    if t == "voice" then
                        model.micTestLevel

                    else
                        0
                , micMonitoring =
                    if t == "voice" then
                        model.micMonitoring

                    else
                        False
              }
            , Cmd.batch
                [ bridgeSend (E.object [ ( "tag", E.string "settings_section_changed" ), ( "data", E.null ) ])
                , if t == "voice" then
                    bridgeSend (E.object [ ( "tag", E.string "list_audio_devices" ), ( "data", E.null ) ])

                  else if model.micTesting then
                    bridgeSend (E.object [ ( "tag", E.string "stop_mic_test" ), ( "data", E.null ) ])

                  else
                    Cmd.none
                ]
            )

        SetFriendsTab tab ->
            ( { model
                | friendsTab = tab
                , friendQuery =
                    if tab == "add" then
                        model.friendQuery

                    else
                        ""
                , searchUsers =
                    if tab == "add" then
                        model.searchUsers

                    else
                        []
              }
            , Cmd.none
            )

        FriendQuery query ->
            ( { model | friendQuery = query, friendSearchAttempted = False }, Cmd.none )

        FindFriends ->
            let
                query =
                    String.trim model.friendQuery
            in
            if String.length query < 2 then
                ( { model | toast = Just "Enter at least 2 characters." }, Cmd.none )

            else
                ( { model | searchUsers = [], friendSearchAttempted = True }, apiSend (encodeApiRequest (ApiGet ("/users?q=" ++ Url.percentEncode query))) )

        ProfileDisplayName s ->
            ( { model | profileDisplayName = s }, Cmd.none )

        ProfileBio s ->
            ( { model | profileBio = s }, Cmd.none )

        ProfileAvatarUrl s ->
            ( { model | profileAvatarUrl = s, profileAvatarPreviewUrl = s }, Cmd.none )

        ProfileBannerUrl s ->
            ( { model | profileBannerUrl = s, profileBannerPreviewUrl = s }, Cmd.none )

        ProfileStatus s ->
            let
                status =
                    statusPreference s
            in
            ( { model | profileStatus = status }
            , bridgeSend (E.object [ ( "tag", E.string "presence_update" ), ( "data", E.string status ) ])
            )

        ProfileTheme s ->
            ( { model | profileTheme = s }
            , Cmd.batch
                [ bridgeSend (E.object [ ( "tag", E.string "set_theme" ), ( "data", E.string s ) ])
                , apiSend (encodeApiRequest (ApiPost "/profile/theme" (Just (E.object [ ( "theme", E.string s ) ]))))
                ]
            )

        SaveProfile ->
            ( model
            , Cmd.batch
                [ apiSend
                    (encodeApiRequest
                        (ApiPost "/profile"
                            (Just
                                (E.object
                                    [ ( "display_name", E.string model.profileDisplayName )
                                    , ( "bio", E.string model.profileBio )
                                    , ( "avatar_url", E.string model.profileAvatarUrl )
                                    , ( "banner_url", E.string model.profileBannerUrl )
                                    , ( "status", E.string model.profileStatus )
                                    , ( "theme", E.string model.profileTheme )
                                    ]
                                )
                            )
                        )
                    )
                , bridgeSend (E.object [ ( "tag", E.string "presence_update" ), ( "data", E.string model.profileStatus ) ])
                ]
            )

        SearchQuery q ->
            ( { model | searchQuery = q }, Cmd.none )

        DoSearch ->
            ( model, setHash ("#search/" ++ model.searchQuery) )

        ClearNotifs ->
            ( model, apiSend (encodeApiRequest (ApiPost "/notifications/clear" (Just (E.object [])))) )

        CreateServer name description ->
            ( model
            , apiSend (encodeApiRequest (ApiPost "/servers" (Just (E.object [ ( "name", E.string name ), ( "description", E.string description ) ]))))
            )

        JoinInvite ->
            case model.invitePreview of
                Just invite ->
                    ( model, apiSend (encodeApiRequest (ApiPost ("/wires/" ++ invite.code ++ "/join") (Just (E.object [])))) )

                Nothing ->
                    ( { model | toast = Just "Open a Wire link like /#wire/CODE to join." }, Cmd.none )

        AcceptCall conversationId ->
            let
                active =
                    { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
            in
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Just active }, callMode = Connected, voice = updateVoiceMode "call" conversationId model.voice }
            , Cmd.batch
                [ bridgeSend (E.object [ ( "tag", E.string "accept_call" ), ( "data", E.int conversationId ) ])
                , playRingtone False
                ]
            )

        DeclineCall conversationId ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle }
            , Cmd.batch
                [ bridgeSend (E.object [ ( "tag", E.string "decline_call" ), ( "data", E.int conversationId ) ])
                , playRingtone False
                , playOutgoingRingtone False
                ]
            )

        EndCall ->
            let
                myId =
                    Maybe.map .id model.me

                markLeft active =
                    let
                        remaining =
                            List.filter (\u -> Just u.userId /= myId) active.users
                    in
                    { active | users = remaining }

                clearedActive =
                    case model.callUI.active of
                        Just a ->
                            let
                                remaining =
                                    List.filter (\u -> Just u.userId /= myId) a.users
                            in
                            if List.isEmpty remaining then
                                Nothing

                            else
                                Just { a | users = remaining }

                        Nothing ->
                            Nothing
            in
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = clearedActive }, callMode = Idle, voice = clearVoice model.voice }
            , bridgeSend (E.object [ ( "tag", E.string "end_call" ), ( "data", E.null ) ])
            )

        ToggleCallOverlay ->
            let
                toggle a =
                    { a | expanded = not a.expanded }
            in
            ( { model | callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = Maybe.map toggle model.callUI.active } }, Cmd.none )

        SetCallPeerConnected roomKind roomId userId connected ->
            ( setRtcPeerConnected roomKind roomId userId connected model, Cmd.none )

        SetCallPeerFailed roomKind roomId userId failed ->
            ( setRtcPeerFailed roomKind roomId userId failed model, Cmd.none )

        RtcAudioState muted deafened ->
            -- The bridge owns the real microphone and playback state; mirror it.
            let
                voice0 =
                    model.voice
            in
            ( { model | voice = { voice0 | muted = muted, deafened = deafened } }, Cmd.none )

        RetryCallPeer userId ->
            case ( model.voice.mode, model.voice.id ) of
                ( Just roomKind, Just roomId ) ->
                    ( model
                        |> setRtcPeerConnected roomKind roomId userId False
                        |> setRtcPeerFailed roomKind roomId userId False
                    , bridgeSend (E.object [ ( "tag", E.string "retry_rtc_peer" ), ( "data", E.int userId ) ])
                    )

                _ ->
                    ( model, Cmd.none )

        StartCall conversationId ->
            let
                active =
                    { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
            in
            ( { model | callUI = { incoming = Nothing, outgoing = model.callUI.outgoing, active = Just active }, callMode = Ringing, voice = updateVoiceMode "call" conversationId model.voice }
            , bridgeSend (E.object [ ( "tag", E.string "start_call" ), ( "data", E.int conversationId ) ])
            )

        JoinCall conversationId ->
            let
                active =
                    { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
            in
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Just active }, callMode = Connected, voice = updateVoiceMode "call" conversationId model.voice }
            , bridgeSend (E.object [ ( "tag", E.string "join_call" ), ( "data", E.int conversationId ) ])
            )

        CallSignal _ _ ->
            ( model, Cmd.none )

        NewThreadModal maybeForumId ->
            ( { model | modal = Just ("new_thread:" ++ maybeIntString maybeForumId), modalTitle = "", modalBody = "", modalUserIds = maybeIntString maybeForumId }, Cmd.none )

        NewForumModal ->
            ( { model | modal = Just "new_forum", modalTitle = "", modalBody = "", modalUserIds = "" }, Cmd.none )

        JoinForum forumId ->
            ( model, apiSend (encodeApiRequest (ApiPost ("/forum/" ++ String.fromInt forumId ++ "/join") (Just (E.object [])))) )

        LeaveForum forumId ->
            ( model, apiSend (encodeApiRequest (ApiPost ("/forum/" ++ String.fromInt forumId ++ "/leave") (Just (E.object [])))) )

        NewDmModal ->
            ( { model | modal = Just "new_dm", modalTitle = "", modalUserIds = "", modalPeopleQuery = "" }, Cmd.none )

        SearchUsersModal ->
            ( { model | modal = Just "search", searchQuery = "" }, Cmd.none )

        ModalTitle s ->
            ( { model | modalTitle = s }, Cmd.none )

        ModalBody s ->
            ( { model | modalBody = s }, Cmd.none )

        ModalUserIds s ->
            ( { model | modalUserIds = s }, Cmd.none )

        ModalBannerUrl s ->
            ( { model | modalBannerUrl = s }, Cmd.none )

        ModalAccentColor s ->
            ( { model | modalAccentColor = s }, Cmd.none )

        SetModalChoice field value ->
            case field of
                "people_query" ->
                    ( { model | modalPeopleQuery = value }, Cmd.none )

                "body" ->
                    ( { model | modalBody = value }, Cmd.none )

                "user_ids" ->
                    ( { model | modalUserIds = value }, Cmd.none )

                "welcome" ->
                    ( { model | modalWelcome = value }, Cmd.none )

                "accent" ->
                    ( { model | modalAccentColor = value }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SubmitModal ->
            submitModal model

        InviteModal serverId ->
            if serverId == 0 then
                ( { model | modal = Just "join_invite", modalTitle = "", modalBody = "0", modalUserIds = "" }, Cmd.none )

            else
                ( { model | modal = Just ("invite:" ++ String.fromInt serverId), modalTitle = "86400", modalBody = "0", modalUserIds = "" }, Cmd.none )

        ChannelModal serverId ->
            ( { model | modal = Just ("channel:" ++ String.fromInt serverId), modalTitle = "", modalBody = "text", modalUserIds = "" }, Cmd.none )

        ChannelModalInCategory serverId categoryId ->
            ( { model
                | modal = Just ("channel:" ++ String.fromInt serverId)
                , modalTitle = ""
                , modalBody = "text"
                , modalUserIds = String.fromInt categoryId
              }
            , Cmd.none
            )

        EditServerModal server ->
            ( { model
                | modal = Just ("edit_server:" ++ String.fromInt server.id)
                , modalTitle = server.name
                , modalBody = server.description
                , modalUserIds = server.iconUrl
                , modalBannerUrl = server.bannerUrl
                , modalWelcome = server.welcomeMessage
                , modalAccentColor = server.accentColor
              }
            , Cmd.none
            )

        OpenDeleteServer server ->
            ( { model
                | modal = Just ("delete_server:" ++ String.fromInt server.id)
                , modalTitle = server.name
                , modalBody = ""
                , ctxMenu = Nothing
              }
            , Cmd.none
            )

        ConfirmDeleteServer serverId ->
            ( model
            , apiSend
                (encodeApiRequest
                    (ApiPost ("/server/" ++ String.fromInt serverId ++ "/delete")
                        (Just (E.object [ ( "confirm_name", E.string (String.trim model.modalBody) ) ]))
                    )
                )
            )

        EditConversationModal conversation ->
            ( { model | modal = Just ("edit_conversation:" ++ String.fromInt conversation.id), modalTitle = conversation.name, modalBody = "" }, Cmd.none )

        AddPeopleModal conversationId ->
            ( { model | modal = Just ("add_people:" ++ String.fromInt conversationId), modalUserIds = "", modalTitle = "", modalPeopleQuery = "" }, Cmd.none )

        ShowUserPopup userId ->
            ( model, setHash ("#profile/" ++ String.fromInt userId) )

        ShowServerProfile serverId userId ->
            ( { model | modal = Just "server_profile", currentServerProfile = Nothing, ctxMenu = Nothing }
            , apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt serverId ++ "/member/" ++ String.fromInt userId ++ "/profile")))
            )

        BridgeEvent tag data ->
            let
                cmd =
                    bridgeSend (E.object [ ( "tag", E.string tag ), ( "data", data ) ])
            in
            case tag of
                "open_voice_settings" ->
                    ( { model | settingsTab = "voice" }
                    , Cmd.batch
                        [ setHash "#settings"
                        , bridgeSend (E.object [ ( "tag", E.string "list_audio_devices" ), ( "data", E.null ) ])
                        ]
                    )

                "join_voice" ->
                    case D.decodeValue D.int data of
                        Ok channelId ->
                            ( { model
                                | voice = updateVoiceMode "voice" channelId model.voice
                                , callMode = InCall
                                , callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }
                              }
                            , cmd
                            )

                        Err _ ->
                            ( model, cmd )

                "start_call" ->
                    case D.decodeValue D.int data of
                        Ok conversationId ->
                            let
                                active =
                                    { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
                            in
                            ( { model | callUI = { incoming = Nothing, outgoing = model.callUI.outgoing, active = Just active }, callMode = Ringing, voice = updateVoiceMode "call" conversationId model.voice }, cmd )

                        Err _ ->
                            ( model, cmd )

                "cancel_call" ->
                    ( { model | callUI = { incoming = model.callUI.incoming, outgoing = Nothing, active = Nothing }, callMode = Idle, voice = clearVoice model.voice }, cmd )

                "leave_voice" ->
                    ( { model | voice = clearVoice model.voice, callMode = Idle }, cmd )

                "toggle_mute" ->
                    if model.voice.deafened then
                        ( model, bridgeSend (E.object [ ( "tag", E.string "toast" ), ( "data", E.string "Undeafen before unmuting." ) ]) )

                    else
                        ( { model | voice = toggleMute model.voice }, bridgeSend (E.object [ ( "tag", E.string "voice_mute" ), ( "data", E.bool (not model.voice.muted) ) ]) )

                "toggle_deafen" ->
                    let
                        nextDeafened =
                            not model.voice.deafened
                    in
                    ( { model | voice = toggleDeafen model.voice }
                    , bridgeSend (E.object [ ( "tag", E.string "voice_deafen" ), ( "data", E.bool nextDeafened ) ])
                    )

                "toggle_speaker" ->
                    ( model, cmd )

                "start_screen_share" ->
                    ( model, cmd )

                "stop_screen_share" ->
                    ( model, cmd )

                "screen_share_started" ->
                    let
                        voice0 =
                            model.voice
                    in
                    ( { model | voice = { voice0 | screenShare = True } }, Cmd.none )

                "screen_share_stopped" ->
                    let
                        voice0 =
                            model.voice
                    in
                    ( { model | voice = { voice0 | screenShare = False } }, Cmd.none )

                _ ->
                    ( model, cmd )

        ReadFile id ->
            ( if id == "profileAvatarFile" then
                { model | profileAvatarUploading = True }

              else if id == "profileBannerFile" then
                { model | profileBannerUploading = True }

              else
                model
            , readFile id
            )

        FileUpload id maybeData ->
            case maybeData of
                Just data ->
                    if id == "profileAvatarFile" then
                        ( { model | profileAvatarUrl = data, profileAvatarPreviewUrl = data, profileAvatarUploading = False }, Cmd.none )

                    else if id == "profileBannerFile" then
                        ( { model | profileBannerUrl = data, profileBannerPreviewUrl = data, profileBannerUploading = False }, Cmd.none )

                    else if id == "serverIconFile" then
                        ( { model | modalUserIds = data }, Cmd.none )

                    else if id == "serverBannerFile" then
                        ( { model | modalBannerUrl = data }, Cmd.none )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( { model
                        | toast = Just "Could not upload that file"
                        , profileAvatarUploading =
                            if id == "profileAvatarFile" then
                                False

                            else
                                model.profileAvatarUploading
                        , profileBannerUploading =
                            if id == "profileBannerFile" then
                                False

                            else
                                model.profileBannerUploading
                      }
                    , Cmd.none
                    )

        CloseCtx ->
            ( { model | ctxMenu = Nothing }, Cmd.none )

        CtxAction idx ->
            case model.ctxMenu |> Maybe.andThen (\menu -> listAt idx menu.items) of
                Just item ->
                    update item.msg { model | ctxMenu = Nothing }

                Nothing ->
                    ( { model | ctxMenu = Nothing }, Cmd.none )

        PresenceState val ->
            case D.decodeValue (D.dict D.string) val of
                Ok statuses ->
                    let
                        merged =
                            case model.me of
                                Just user ->
                                    Dict.insert (String.fromInt user.id) model.profileStatus statuses

                                Nothing ->
                                    statuses
                    in
                    ( { model | userStatuses = merged }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        PresenceOnline uid status ->
            ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )

        PresenceOffline uid ->
            let
                isSelf =
                    Maybe.map (\user -> user.id == uid) model.me |> Maybe.withDefault False

                statuses =
                    if isSelf && model.wsConnected then
                        Dict.insert (String.fromInt uid) model.profileStatus model.userStatuses

                    else
                        Dict.remove (String.fromInt uid) model.userStatuses
            in
            ( { model | userStatuses = statuses }, Cmd.none )

        PresenceStatus uid status ->
            ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )

        SetMyStatus status ->
            let
                statuses =
                    case model.me of
                        Just user ->
                            Dict.insert (String.fromInt user.id) status model.userStatuses

                        Nothing ->
                            model.userStatuses
            in
            ( { model | profileStatus = status, userStatuses = statuses }, Cmd.none )

        RtcJoinFailed _ ->
            ( { model | voice = clearVoice model.voice, callMode = Idle, callUI = { incoming = model.callUI.incoming, outgoing = Nothing, active = Nothing } }, Cmd.none )

        AudioDevices val ->
            case D.decodeValue audioDevicesDecoder val of
                Ok devices ->
                    ( { model
                        | audioInputs = devices.inputs
                        , audioOutputs = devices.outputs
                        , selectedAudioInput = devices.selectedInput
                        , selectedAudioOutput = devices.selectedOutput
                        , outputSelectionSupported = devices.outputSupported
                        , voiceProcessingMode = devices.processingMode
                        , krispAvailable = devices.krispAvailable
                        , micMonitoring = devices.micMonitoring
                      }
                    , Cmd.none
                    )

                Err _ ->
                    ( model, Cmd.none )

        SelectAudioInput deviceId ->
            ( { model | selectedAudioInput = deviceId, micTesting = False, micTestLevel = 0, micMonitoring = False }
            , bridgeSend (E.object [ ( "tag", E.string "select_audio_input" ), ( "data", E.string deviceId ) ])
            )

        SelectAudioOutput deviceId ->
            ( { model | selectedAudioOutput = deviceId }
            , bridgeSend (E.object [ ( "tag", E.string "select_audio_output" ), ( "data", E.string deviceId ) ])
            )

        SelectVoiceProcessing processingMode ->
            ( { model
                | voiceProcessingMode = processingMode
                , micTesting = False
                , micTestLevel = 0
                , micMonitoring = False
              }
            , bridgeSend (E.object [ ( "tag", E.string "select_voice_processing" ), ( "data", E.string processingMode ) ])
            )

        ToggleMicTest ->
            let
                testing =
                    not model.micTesting
            in
            ( { model
                | micTesting = testing
                , micTestLevel =
                    if testing then
                        model.micTestLevel

                    else
                        0
                , micMonitoring =
                    if testing then
                        model.micMonitoring

                    else
                        False
              }
            , bridgeSend
                (E.object
                    [ ( "tag"
                      , E.string
                            (if testing then
                                "start_mic_test"

                             else
                                "stop_mic_test"
                            )
                      )
                    , ( "data", E.null )
                    ]
                )
            )

        ToggleMicMonitor ->
            let
                monitoring =
                    model.micTesting && not model.micMonitoring
            in
            ( { model | micMonitoring = monitoring }
            , bridgeSend (E.object [ ( "tag", E.string "set_mic_monitor" ), ( "data", E.bool monitoring ) ])
            )

        MicTestLevel level ->
            ( { model | micTestLevel = level }, Cmd.none )

        MicTestFailed message ->
            ( { model | micTesting = False, micTestLevel = 0, micMonitoring = False, toast = Just message }, Cmd.none )

        StartScreenShare ->
            ( model, bridgeSend (E.object [ ( "tag", E.string "start_screen_share" ), ( "data", E.null ) ]) )

        StopScreenShare ->
            let
                voice0 =
                    model.voice
            in
            ( { model | voice = { voice0 | screenShare = False } }, bridgeSend (E.object [ ( "tag", E.string "stop_screen_share" ), ( "data", E.null ) ]) )

        ToggleCategory catId ->
            let
                newSet =
                    if Set.member catId model.collapsedCategories then
                        Set.remove catId model.collapsedCategories

                    else
                        Set.insert catId model.collapsedCategories
            in
            ( { model | collapsedCategories = newSet }, Cmd.none )

        CreateCategoryModal serverId ->
            ( { model | modal = Just ("create_category:" ++ String.fromInt serverId), modalTitle = "", modalBody = "", modalUserIds = "" }, Cmd.none )

        EditCategoryModal serverId category ->
            ( { model
                | modal = Just ("edit_category:" ++ String.fromInt serverId ++ ":" ++ String.fromInt category.id)
                , modalTitle = category.name
              }
            , Cmd.none
            )

        DeleteCategory serverId catId ->
            ( { model | modal = Nothing }, apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/category/" ++ String.fromInt catId ++ "/delete") Nothing)) )

        MoveChannelToCategory channelId catId ->
            ( model, apiSend (encodeApiRequest (ApiPost ("/channel/" ++ String.fromInt channelId ++ "/move") (Just (E.object [ ( "category_id", maybeInt catId ) ])))) )

        ShortcutAction action ->
            case action of
                "help" ->
                    ( { model | modal = Just "keyboard_shortcuts", ctxMenu = Nothing }, Cmd.none )

                "search" ->
                    ( { model | modal = Just "search", ctxMenu = Nothing }, Cmd.none )

                "settings" ->
                    ( { model | ctxMenu = Nothing, modal = Nothing }, setHash "#settings" )

                "notifications" ->
                    ( { model | ctxMenu = Nothing, modal = Nothing }, setHash "#notifications" )

                "new_server" ->
                    ( { model | ctxMenu = Nothing, modal = Nothing }, setHash "#new-server" )

                "upload" ->
                    case model.active of
                        DmView _ ->
                            ( model, bridgeSend (E.object [ ( "tag", E.string "pick_attachments" ), ( "data", E.null ) ]) )

                        ChannelView _ ->
                            ( model, bridgeSend (E.object [ ( "tag", E.string "pick_attachments" ), ( "data", E.null ) ]) )

                        _ ->
                            ( { model | toast = Just "Open a DM or text channel before uploading files." }, Cmd.none )

                "emoji_picker" ->
                    case model.active of
                        DmView _ ->
                            ( { model | modal = Just "emoji_picker", ctxMenu = Nothing }, Cmd.none )

                        ChannelView _ ->
                            ( { model | modal = Just "emoji_picker", ctxMenu = Nothing }, Cmd.none )

                        _ ->
                            ( { model | toast = Just "Open a DM or text channel to use the emoji picker." }, Cmd.none )

                "new_group" ->
                    update NewDmModal model

                "answer_call" ->
                    case model.callUI.incoming of
                        Just incoming ->
                            update (AcceptCall incoming.conversationId) model

                        Nothing ->
                            ( model, Cmd.none )

                "decline_call" ->
                    case model.callUI.incoming of
                        Just incoming ->
                            update (DeclineCall incoming.conversationId) model

                        Nothing ->
                            ( model, Cmd.none )

                "start_call" ->
                    case model.active of
                        DmView conversationId ->
                            if model.voice.mode == Nothing then
                                update (StartCall conversationId) model

                            else if isJoinedCall conversationId model then
                                ( { model | toast = Just "You are already connected to this call." }, Cmd.none )

                            else
                                ( { model | toast = Just "Leave the current voice session before starting another call." }, Cmd.none )

                        _ ->
                            ( { model | toast = Just "Open a DM or group conversation to start a call." }, Cmd.none )

                "active_audio" ->
                    case ( model.voice.mode, model.voice.id ) of
                        ( Just "voice", Just channelId ) ->
                            ( model, setHash ("#voice/" ++ String.fromInt channelId) )

                        ( Just "call", Just conversationId ) ->
                            ( model, setHash ("#dm/" ++ String.fromInt conversationId) )

                        _ ->
                            ( { model | toast = Just "You are not connected to a voice session." }, Cmd.none )

                "prev_server" ->
                    navigateServer -1 model

                "next_server" ->
                    navigateServer 1 model

                "toggle_mute" ->
                    if model.voice.mode == Nothing then
                        ( { model | toast = Just "Join a call or voice channel before toggling mute." }, Cmd.none )

                    else
                        update (BridgeEvent "toggle_mute" E.null) model

                "toggle_deafen" ->
                    if model.voice.mode == Nothing then
                        ( { model | toast = Just "Join a call or voice channel before toggling deafen." }, Cmd.none )

                    else
                        update (BridgeEvent "toggle_deafen" E.null) model

                "next_route" ->
                    navigateRelative 1 model

                "prev_route" ->
                    navigateRelative -1 model

                "next_unread" ->
                    navigateUnread 1 model

                "prev_unread" ->
                    navigateUnread -1 model

                "screen_share" ->
                    if model.voice.mode == Nothing then
                        ( { model | toast = Just "Join a call or voice channel before sharing your screen." }, Cmd.none )

                    else if model.voice.screenShare then
                        update (BridgeEvent "stop_screen_share" E.null) model

                    else
                        update (BridgeEvent "start_screen_share" E.null) model

                "toggle_call_window" ->
                    case model.callUI.active of
                        Just _ ->
                            update ToggleCallOverlay model

                        Nothing ->
                            ( { model | toast = Just "There is no active call window to toggle." }, Cmd.none )

                "close_dm" ->
                    case model.active of
                        DmView conversationId ->
                            case List.filter (\conversation -> conversation.id == conversationId) model.convs |> List.head of
                                Just conversation ->
                                    if conversation.memberCount == 2 then
                                        update (CloseConversation conversationId) model

                                    else
                                        ( { model | toast = Just "Group conversations are left from their menu so you cannot close one by accident." }, Cmd.none )

                                Nothing ->
                                    ( model, Cmd.none )

                        _ ->
                            ( { model | toast = Just "Open a direct message before closing it." }, Cmd.none )

                "edit_last_message" ->
                    case model.me of
                        Just me ->
                            model.msg
                                |> List.reverse
                                |> List.filter (\message -> message.id > 0 && message.userId == me.id && message.kind == "text" && message.forwardedFrom == Nothing)
                                |> List.head
                                |> Maybe.map (\message -> update (StartEditMessage message) model)
                                |> Maybe.withDefault ( model, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        LoadMoreMessages ->
            if model.loadingOlderMessages || not model.hasOlderMessages then
                ( model, Cmd.none )

            else
                case ( model.active, model.msg ) of
                    ( DmView id, firstMsg :: _ ) ->
                        ( { model | loadingOlderMessages = True }, Cmd.batch [ bridgeSend (E.object [ ( "tag", E.string "preserve_message_scroll" ), ( "data", E.null ) ]), apiSend (encodeApiRequest (ApiGet ("/messages?scope=direct&scope_id=" ++ String.fromInt id ++ "&before=" ++ String.fromInt firstMsg.id))) ] )

                    ( ChannelView id, firstMsg :: _ ) ->
                        ( { model | loadingOlderMessages = True }, Cmd.batch [ bridgeSend (E.object [ ( "tag", E.string "preserve_message_scroll" ), ( "data", E.null ) ]), apiSend (encodeApiRequest (ApiGet ("/messages?scope=channel&scope_id=" ++ String.fromInt id ++ "&before=" ++ String.fromInt firstMsg.id))) ] )

                    _ ->
                        ( model, Cmd.none )


handleMe : E.Value -> Model -> ( Model, Cmd Msg )
handleMe val model =
    case D.decodeValue decodeUser (fromApiField "user" val) of
        Ok user ->
            let
                userValue =
                    fromApiField "user" val

                avatarSource =
                    D.decodeValue (D.field "avatar_source_url" D.string) userValue |> Result.withDefault user.avatarUrl

                bannerSource =
                    D.decodeValue (D.field "banner_source_url" D.string) userValue |> Result.withDefault user.bannerUrl

                presence =
                    statusPreference (statusToString user.status)
            in
            ( { model
                | me = Just user
                , csrf = fromApiFieldStr "csrf" val
                , serverTime = fromApiFieldInt "server_time" val
                , booting = False
                , authBusy = False
                , profileDisplayName = user.displayName
                , profileBio = user.bio
                , profileAvatarUrl = avatarSource
                , profileBannerUrl = bannerSource
                , profileAvatarPreviewUrl = user.avatarUrl
                , profileBannerPreviewUrl = user.bannerUrl
                , profileAvatarUploading = False
                , profileBannerUploading = False
                , profileStatus = presence
                , profileTheme = user.theme
                , userStatuses = Dict.insert (String.fromInt user.id) presence model.userStatuses
              }
            , Cmd.batch
                [ bridgeSend (E.object [ ( "tag", E.string "connect_ws" ), ( "data", E.null ) ])
                , bridgeSend (E.object [ ( "tag", E.string "presence_update" ), ( "data", E.string presence ) ])
                , bridgeSend (E.object [ ( "tag", E.string "set_theme" ), ( "data", E.string user.theme ) ])
                , apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                , routeCmd model.active
                ]
            )

        Err _ ->
            ( model, Cmd.none )


handleSync : E.Value -> Model -> ( Model, Cmd Msg )
handleSync val model =
    case D.decodeValue decodeSyncData val of
        Ok data ->
            let
                failed name =
                    List.member name data.syncWarnings

                nextConvs =
                    if failed "conversations" then
                        model.convs

                    else
                        sortConvs (mergeConversationDetails model.convs data.conversations)

                nextModel =
                    { model
                        | notifs =
                            if failed "notifications" then
                                model.notifs

                            else
                                data.notifications
                        , convs = nextConvs
                        , servers =
                            if failed "servers" then
                                model.servers

                            else
                                data.servers
                        , friends =
                            if failed "friends" then
                                model.friends

                            else
                                data.friends
                        , serverTime = data.now
                    }

                redirectIfGone =
                    case model.active of
                        DmView id ->
                            if failed "conversations" || List.any (\c -> c.id == id) nextConvs then
                                -- A degraded conversation sync must never throw the user
                                -- out of a chat that was valid one request ago.
                                ( { nextModel | pendingConversationId = Nothing }, Cmd.none )

                            else if model.pendingConversationId == Just id then
                                -- stale sync, wait for the next one
                                ( nextModel, Cmd.none )

                            else
                                ( { nextModel | msg = [] }, setHash "#dms" )

                        _ ->
                            ( nextModel, Cmd.none )
                ( synced, syncCmd ) =
                    redirectIfGone
            in
            ( captureEntryRead synced synced.msg, syncCmd )

        Err _ ->
            ( model, Cmd.none )


mergeConversationDetails : List Conversation -> List Conversation -> List Conversation
mergeConversationDetails previous summaries =
    let
        preserveMembers summary =
            case List.filter (\old -> old.id == summary.id && not (List.isEmpty old.members)) previous |> List.head of
                Just old ->
                    { summary | members = old.members, memberCount = Basics.max summary.memberCount (List.length old.members) }

                Nothing ->
                    summary
    in
    List.map preserveMembers summaries


handleList : Decoder (List a) -> (List a -> Model -> Model) -> E.Value -> Model -> ( Model, Cmd Msg )
handleList decoder apply val model =
    case D.decodeValue decoder val of
        Ok items ->
            ( apply items model, Cmd.none )

        Err _ ->
            ( model, Cmd.none )


optimisticEcho : Message -> Message -> Bool
optimisticEcho real local =
    local.id < 0
        && local.userId == real.userId
        && local.scope == real.scope
        && local.scopeId == real.scopeId
        && local.replyToId == real.replyToId
        && String.trim local.body == String.trim real.body


dropOneOptimisticEcho : Message -> List Message -> ( List Message, Maybe Int )
dropOneOptimisticEcho real messages =
    dropOneOptimisticEchoHelp real messages []


dropOneOptimisticEchoHelp : Message -> List Message -> List Message -> ( List Message, Maybe Int )
dropOneOptimisticEchoHelp real messages acc =
    case messages of
        [] ->
            ( List.reverse acc, Nothing )

        m :: rest ->
            if optimisticEcho real m then
                ( List.reverse acc ++ rest, Just m.id )

            else
                dropOneOptimisticEchoHelp real rest (m :: acc)


forgetOptimistic : Int -> Model -> Model
forgetOptimistic id model =
    { model
        | outbox = Dict.remove id model.outbox
        , failedMsgIds = Set.remove id model.failedMsgIds
        , pendingMessages = Dict.remove id model.pendingMessages
    }


absorbOptimisticEchoes : List Message -> Model -> Model
absorbOptimisticEchoes incoming model =
    let
        ( msg, dropped ) =
            List.foldl
                (\real ( acc, ids ) ->
                    case dropOneOptimisticEcho real acc of
                        ( next, Just id ) ->
                            ( next, id :: ids )

                        ( next, Nothing ) ->
                            ( next, ids )
                )
                ( model.msg, [] )
                incoming
    in
    List.foldl forgetOptimistic { model | msg = msg } dropped


handleMessages : String -> E.Value -> Model -> ( Model, Cmd Msg )
handleMessages tag val model =
    if not (messageRequestApplies tag model.active) then
        ( model, Cmd.none )

    else
        case D.decodeValue (D.list decodeMessage) val of
            Ok items ->
                let
                    cmd =
                        case model.active of
                            DmView id ->
                                if String.isEmpty model.csrf then
                                    Cmd.none

                                else
                                    apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt id ++ "/read") (Just (E.object []))))

                            _ ->
                                Cmd.none

                    incoming =
                        List.filter (\m -> m.deletedAt == Nothing) (List.reverse items)

                    applies =
                        List.all (messageApplies model.active) incoming

                    olderPage =
                        String.contains "&before=" tag

                    absorbed =
                        if olderPage then
                            model

                        else
                            absorbOptimisticEchoes incoming model

                    incomingIds =
                        Set.fromList (List.map .id incoming)

                    preserved =
                        List.filter (\m -> messageApplies model.active m && not (Set.member m.id incomingIds)) absorbed.msg

                    merged =
                        List.sortBy .createdAt (incoming ++ preserved)

                    hasOlder =
                        if List.length items < 80 then
                            False

                        else
                            model.hasOlderMessages
                in
                if applies then
                    let
                        loaded =
                            { absorbed | msg = merged, loadingOlderMessages = False, hasOlderMessages = hasOlder }

                        next =
                            if olderPage then
                                loaded

                            else
                                captureEntryRead loaded merged
                    in
                    ( next
                    , if olderPage then
                        Cmd.batch [ cmd, bridgeSend (E.object [ ( "tag", E.string "restore_message_scroll" ), ( "data", E.null ) ]) ]

                      else
                        Cmd.batch [ cmd, bridgeSend (E.object [ ( "tag", E.string "scroll_messages_to_bottom" ), ( "data", E.bool True ) ]) ]
                    )

                else
                    ( { model | loadingOlderMessages = False }, Cmd.none )

            Err err ->
                ( { model | toast = Just ("Could not load messages: " ++ D.errorToString err), loadingOlderMessages = False }, Cmd.none )


handleThread : E.Value -> Model -> ( Model, Cmd Msg )
handleThread val model =
    case D.decodeValue threadDetailDecoder val of
        Ok detail ->
            ( { model | currentThread = Just detail.thread, replies = detail.replies }
            , wsSend (E.object [ ( "type", E.string "subscribe" ), ( "key", E.string ("forum:" ++ String.fromInt detail.thread.forumId) ) ])
            )

        Err _ ->
            ( model, Cmd.none )


handleConversationDetail : E.Value -> Model -> ( Model, Cmd Msg )
handleConversationDetail val model =
    case ( D.decodeValue (D.at [ "conversation", "id" ] D.int) val, D.decodeValue (D.field "members" (D.list decodeMemberUser)) val ) of
        ( Ok conversationId, Ok members ) ->
            let
                updateConversation conversation =
                    if conversation.id == conversationId then
                        { conversation | members = members, memberCount = List.length members }

                    else
                        conversation
            in
            ( { model
                | convs = List.map updateConversation model.convs
                , conversationMembers = Dict.insert conversationId members model.conversationMembers
              }
            , Cmd.none
            )

        _ ->
            ( { model | toast = Just "Could not load group members" }, Cmd.none )


handleMessageSent : Maybe Int -> E.Value -> Model -> ( Model, Cmd Msg )
handleMessageSent requestId val model =
    case D.decodeValue decodeMessage val of
        Ok message ->
            let
                acknowledgedId =
                    Maybe.withDefault 0 requestId

                absorbed =
                    absorbOptimisticEchoes [ message ] model

                remaining =
                    List.filter (\m -> m.id /= acknowledgedId && m.id /= message.id) absorbed.msg

                newMsgs =
                    if messageApplies model.active message then
                        List.sortBy .createdAt (remaining ++ [ message ])

                    else
                        remaining

                updateConversation conversation =
                    if message.scope == "direct" && conversation.id == message.scopeId then
                        { conversation
                            | lastBody = Just message.body
                            , lastMessageId = Just message.id
                            , lastSenderId = message.userId
                            , lastSenderName = message.displayName
                            , lastSenderUsername = message.username
                            , updatedAt = message.createdAt
                            , unread = 0
                        }

                    else
                        conversation
            in
            ( { absorbed
                | msg = newMsgs
                , convs = List.map updateConversation absorbed.convs
                , outbox = Dict.remove acknowledgedId absorbed.outbox
                , failedMsgIds = Set.remove acknowledgedId absorbed.failedMsgIds
                , pendingMessages = Dict.remove acknowledgedId absorbed.pendingMessages
              }
            , Cmd.none
            )

        Err err ->
            ( { model | toast = Just ("Message sent, but could not display it yet: " ++ D.errorToString err) }, routeCmd model.active )


handleCreateConversation : E.Value -> Model -> ( Model, Cmd Msg )
handleCreateConversation val model =
    case D.decodeValue (D.field "id" D.int) val of
        Ok id ->
            ( { model | pendingConversationId = Just id }
            , Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                , setHash ("#dm/" ++ String.fromInt id)
                ]
            )

        Err _ ->
            ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )


handleCreateThread : E.Value -> Model -> ( Model, Cmd Msg )
handleCreateThread val model =
    case D.decodeValue (D.field "id" D.int) val of
        Ok id ->
            ( model, setHash ("#t/" ++ String.fromInt id) )

        Err _ ->
            ( model, apiSend (encodeApiRequest (ApiGet "/forums")) )


handleCreateForum : E.Value -> Model -> ( Model, Cmd Msg )
handleCreateForum val model =
    case D.decodeValue (D.field "id" D.int) val of
        Ok id ->
            ( { model | modal = Nothing, modalTitle = "", modalBody = "", modalUserIds = "" }
            , Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/forums")), setHash ("#f/" ++ String.fromInt id) ]
            )

        Err _ ->
            ( { model | modal = Nothing }, apiSend (encodeApiRequest (ApiGet "/forums")) )


submitModal : Model -> ( Model, Cmd Msg )
submitModal model =
    case model.modal of
        Just kind ->
            if String.startsWith "new_thread" kind then
                case String.toInt (String.trim model.modalUserIds) of
                    Just forumId ->
                        if String.isEmpty (String.trim model.modalTitle) then
                            ( { model | toast = Just "Add a thread title" }, Cmd.none )

                        else
                            ( { model | modal = Nothing }
                            , apiSend
                                (encodeApiRequest
                                    (ApiPost "/threads"
                                        (Just
                                            (E.object
                                                [ ( "forum_id", E.int forumId )
                                                , ( "title", E.string model.modalTitle )
                                                , ( "body", E.string model.modalBody )
                                                ]
                                            )
                                        )
                                    )
                                )
                            )

                    Nothing ->
                        ( { model | toast = Just "Choose a category ID" }, Cmd.none )

            else if kind == "new_forum" then
                if String.length (String.trim model.modalTitle) < 2 then
                    ( { model | toast = Just "Add a forum name" }, Cmd.none )

                else
                    ( { model | modal = Nothing }
                    , apiSend
                        (encodeApiRequest
                            (ApiPost "/forums"
                                (Just
                                    (E.object
                                        [ ( "name", E.string model.modalTitle )
                                        , ( "slug", E.string model.modalUserIds )
                                        , ( "description", E.string model.modalBody )
                                        ]
                                    )
                                )
                            )
                        )
                    )

            else if kind == "new_dm" then
                let
                    usernames =
                        csvUsernames model.modalUserIds
                in
                if List.isEmpty usernames || List.length usernames > 49 then
                    ( { model | toast = Just "Choose between 1 and 49 people" }, Cmd.none )

                else
                    ( { model | modal = Nothing }
                    , apiSend
                        (encodeApiRequest
                            (ApiPost "/conversations"
                                (Just
                                    (E.object
                                        [ ( "usernames", E.list E.string usernames )
                                        , ( "name", E.string model.modalTitle )
                                        ]
                                    )
                                )
                            )
                        )
                    )

            else if String.startsWith "forward_message:" kind || kind == "keyboard_shortcuts" then
                ( model, Cmd.none )

            else if kind == "search" then
                ( { model | modal = Nothing }, setHash ("#search/" ++ model.searchQuery) )

            else if String.startsWith "channel:" kind then
                case String.toInt (String.dropLeft 8 kind) of
                    Just serverId ->
                        if String.isEmpty (String.trim model.modalTitle) then
                            ( { model | toast = Just "Add a channel name" }, Cmd.none )

                        else
                            ( { model | modal = Nothing }
                            , apiSend
                                (encodeApiRequest
                                    (ApiPost ("/server/" ++ String.fromInt serverId ++ "/channels")
                                        (Just
                                            (E.object
                                                [ ( "name", E.string model.modalTitle )
                                                , ( "kind", E.string model.modalBody )
                                                , ( "category_id", maybeInt (String.toInt (String.trim model.modalUserIds)) )
                                                ]
                                            )
                                        )
                                    )
                                )
                            )

                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if String.startsWith "invite:" kind then
                case String.toInt (String.dropLeft 7 kind) of
                    Just serverId ->
                        ( { model | modal = Nothing }
                        , apiSend
                            (encodeApiRequest
                                (ApiPost ("/server/" ++ String.fromInt serverId ++ "/wires")
                                    (Just
                                        (E.object
                                            [ ( "channel_id", maybeInt (String.toInt (String.trim model.modalUserIds)) )
                                            , ( "max_uses", E.int (Maybe.withDefault 0 (String.toInt (String.trim model.modalBody))) )
                                            , ( "expires_in", E.int (Maybe.withDefault 86400 (String.toInt model.modalTitle)) )
                                            ]
                                        )
                                    )
                                )
                            )
                        )

                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if kind == "join_invite" then
                let
                    code =
                        wireCodeFromInput model.modalUserIds
                in
                if String.isEmpty code then
                    ( { model | toast = Just "Enter a Wire code" }, Cmd.none )

                else
                    ( { model | modal = Nothing }
                    , setHash ("#wire/" ++ code)
                    )

            else if String.startsWith "create_category:" kind then
                case String.toInt (String.dropLeft 16 kind) of
                    Just serverId ->
                        if String.isEmpty (String.trim model.modalTitle) then
                            ( { model | toast = Just "Add a category name" }, Cmd.none )

                        else
                            ( { model | modal = Nothing }
                            , apiSend
                                (encodeApiRequest
                                    (ApiPost ("/server/" ++ String.fromInt serverId ++ "/categories")
                                        (Just
                                            (E.object
                                                [ ( "name", E.string model.modalTitle ) ]
                                            )
                                        )
                                    )
                                )
                            )

                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if String.startsWith "edit_category:" kind then
                case String.split ":" (String.dropLeft 14 kind) of
                    [ serverIdText, categoryIdText ] ->
                        case ( String.toInt serverIdText, String.toInt categoryIdText ) of
                            ( Just serverId, Just categoryId ) ->
                                if String.isEmpty (String.trim model.modalTitle) then
                                    ( { model | toast = Just "Add a category name" }, Cmd.none )

                                else
                                    ( { model | modal = Nothing }
                                    , apiSend
                                        (encodeApiRequest
                                            (ApiPost ("/server/" ++ String.fromInt serverId ++ "/category/" ++ String.fromInt categoryId)
                                                (Just
                                                    (E.object
                                                        [ ( "name", E.string model.modalTitle ) ]
                                                    )
                                                )
                                            )
                                        )
                                    )

                            _ ->
                                ( { model | modal = Nothing }, Cmd.none )

                    _ ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if String.startsWith "edit_conversation:" kind then
                case String.toInt (String.dropLeft 18 kind) of
                    Just conversationId ->
                        if String.isEmpty (String.trim model.modalTitle) then
                            ( { model | toast = Just "Add a group name" }, Cmd.none )

                        else
                            ( { model | modal = Nothing }
                            , apiSend
                                (encodeApiRequest
                                    (ApiPost ("/conversation/" ++ String.fromInt conversationId)
                                        (Just
                                            (E.object
                                                [ ( "name", E.string model.modalTitle ) ]
                                            )
                                        )
                                    )
                                )
                            )

                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if String.startsWith "add_people:" kind then
                case String.toInt (String.dropLeft 11 kind) of
                    Just conversationId ->
                        let
                            usernames =
                                csvUsernames model.modalUserIds

                            remaining =
                                model.convs |> List.filter (\c -> c.id == conversationId) |> List.head |> Maybe.map (\c -> Basics.max 0 (50 - c.memberCount)) |> Maybe.withDefault 0
                        in
                        if List.isEmpty usernames || List.length usernames > remaining then
                            ( { model | toast = Just "Choose people within the group limit of 50 members" }, Cmd.none )

                        else
                            ( { model | modal = Nothing }
                            , apiSend
                                (encodeApiRequest
                                    (ApiPost ("/conversation/" ++ String.fromInt conversationId ++ "/members")
                                        (Just
                                            (E.object
                                                [ ( "usernames", E.list E.string usernames ) ]
                                            )
                                        )
                                    )
                                )
                            )

                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if String.startsWith "edit_server:" kind then
                case String.toInt (String.dropLeft 12 kind) of
                    Just serverId ->
                        if String.length (String.trim model.modalTitle) < 2 then
                            ( { model | toast = Just "Server name must be at least 2 characters" }, Cmd.none )

                        else if not (validAccentColor model.modalAccentColor) then
                            ( { model | toast = Just "Accent color must use a six-digit hex value like #5865f2" }, Cmd.none )

                        else
                            ( { model | modal = Nothing }
                            , apiSend
                                (encodeApiRequest
                                    (ApiPost ("/server/" ++ String.fromInt serverId)
                                        (Just
                                            (E.object
                                                [ ( "name", E.string model.modalTitle )
                                                , ( "description", E.string model.modalBody )
                                                , ( "icon_url", E.string model.modalUserIds )
                                                , ( "banner_url", E.string model.modalBannerUrl )
                                                , ( "accent_color", E.string model.modalAccentColor )
                                                , ( "welcome_message", E.string model.modalWelcome )
                                                ]
                                            )
                                        )
                                    )
                                )
                            )

                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else
                ( { model | modal = Nothing }, Cmd.none )

        Nothing ->
            ( model, Cmd.none )


handleReplyCreated : E.Value -> Model -> ( Model, Cmd Msg )
handleReplyCreated val model =
    case D.decodeValue decodeReply val of
        Ok reply ->
            ( { model | replies = model.replies ++ [ reply ], inputText = "" }, Cmd.none )

        Err _ ->
            ( model, Cmd.none )


handleThreadVote : E.Value -> Model -> ( Model, Cmd Msg )
handleThreadVote val model =
    case D.decodeValue threadVoteDecoder val of
        Ok vote ->
            let
                updateThread t =
                    if t.id == vote.threadId then
                        { t | score = vote.score, userVote = vote.userVote }

                    else
                        t
            in
            ( { model
                | threads = List.map updateThread model.threads
                , currentThread = Maybe.map updateThread model.currentThread
              }
            , Cmd.none
            )

        Err _ ->
            ( { model | toast = Just "Could not update vote." }, Cmd.none )


threadVoteDecoder : Decoder { threadId : Int, score : Int, userVote : Int }
threadVoteDecoder =
    D.map3 (\threadId score userVote -> { threadId = threadId, score = score, userVote = userVote })
        (D.field "thread_id" D.int)
        (D.field "score" D.int)
        (D.field "user_vote" D.int)


threadDetailDecoder : Decoder { thread : ForumThread, replies : List Reply }
threadDetailDecoder =
    D.map2 (\thread replies -> { thread = thread, replies = replies })
        (D.field "thread" decodeThread)
        (D.field "replies" (D.list decodeReply))


handleServerData : E.Value -> Model -> ( Model, Cmd Msg )
handleServerData val model =
    case D.decodeValue serverDataDecoder val of
        Ok data ->
            let
                isVisibleServer =
                    model.currentServer
                        |> Maybe.map (\current -> current.server.id == data.server.id)
                        |> Maybe.withDefault False

                roleColors =
                    Dict.fromList (List.map (\member -> ( member.user.id, member.roleColor )) data.members)

                refreshVisibleRoleColor message =
                    if isVisibleServer && message.scope == "channel" then
                        case Dict.get message.userId roleColors of
                            Just color ->
                                { message | roleColor = color }

                            Nothing ->
                                message

                    else
                        message
            in
            ( { model
                | currentServer = Just data
                , serverCache = Dict.insert data.server.id data model.serverCache
                , msg = List.map refreshVisibleRoleColor model.msg
              }
            , Cmd.none
            )

        Err _ ->
            ( { model | toast = Just "Server saved" }, routeCmd model.active )


serverProfileRoleDecoder : Decoder ServerProfileRole
serverProfileRoleDecoder =
    D.map5 ServerProfileRole
        (D.field "id" D.int)
        (D.field "name" D.string)
        (D.field "color" D.string |> defaultValue "")
        (D.field "permissions" D.int |> defaultValue 0)
        (D.field "position" D.int |> defaultValue 0)


serverProfileDecoder : Decoder ServerProfile
serverProfileDecoder =
    D.map6 ServerProfile
        (D.field "server_id" D.int)
        (D.field "server_name" D.string)
        (D.field "member" decodeServerMember)
        (D.field "roles" (D.list serverProfileRoleDecoder) |> defaultValue [])
        (D.field "can_manage_roles" D.bool |> defaultValue False)
        (D.field "can_ban_members" D.bool |> defaultValue False)


handleServerProfile : E.Value -> Model -> ( Model, Cmd Msg )
handleServerProfile val model =
    case D.decodeValue serverProfileDecoder val of
        Ok profile ->
            ( { model | modal = Just "server_profile", currentServerProfile = Just profile }, Cmd.none )

        Err _ ->
            ( { model | modal = Nothing, currentServerProfile = Nothing, toast = Just "Could not load that server profile." }, Cmd.none )


handleServerDeleted : E.Value -> Model -> ( Model, Cmd Msg )
handleServerDeleted val model =
    case D.decodeValue (D.field "id" D.int) val of
        Ok serverId ->
            let
                deletedCurrent =
                    model.currentServer
                        |> Maybe.map (\data -> data.server.id == serverId)
                        |> Maybe.withDefault False

                navigation =
                    if deletedCurrent then
                        setHash "#"

                    else
                        Cmd.none
            in
            ( { model
                | servers = List.filter (\server -> server.id /= serverId) model.servers
                , serverCache = Dict.remove serverId model.serverCache
                , currentServer =
                    case model.currentServer of
                        Just data ->
                            if data.server.id == serverId then
                                Nothing

                            else
                                Just data

                        Nothing ->
                            Nothing
                , modal = Nothing
                , currentServerProfile = Nothing
                , ctxMenu = Nothing
                , toast = Just "Server deleted"
              }
            , Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet "/servers"))
                , navigation
                ]
            )

        Err _ ->
            ( { model | toast = Just "The server was deleted, but the local list could not be updated cleanly. Refreshing…" }
            , apiSend (encodeApiRequest (ApiGet "/servers"))
            )


reactionChangeDecoder : Decoder { messageId : Int, emoji : String, count : Int, added : Bool, userId : Int }
reactionChangeDecoder =
    D.map5
        (\messageId emoji count added userId -> { messageId = messageId, emoji = emoji, count = count, added = added, userId = userId })
        (D.field "message_id" D.int)
        (D.field "emoji" D.string)
        (D.field "count" D.int)
        (D.field "added" D.bool)
        (D.field "user_id" D.int)


handleReactionChange : E.Value -> Model -> ( Model, Cmd Msg )
handleReactionChange val model =
    case D.decodeValue reactionChangeDecoder val of
        Ok change ->
            let
                myId =
                    Maybe.map .id model.me

                updateReaction reactions =
                    let
                        existing =
                            List.filter (\reaction -> reaction.emoji == change.emoji) reactions |> List.head

                        wasMine =
                            existing |> Maybe.map .me |> Maybe.withDefault False

                        nextMine =
                            if myId == Just change.userId then
                                change.added

                            else
                                wasMine

                        next =
                            { emoji = change.emoji, count = change.count, me = nextMine }

                        without =
                            List.filter (\reaction -> reaction.emoji /= change.emoji) reactions
                    in
                    if change.count <= 0 then
                        without

                    else
                        without ++ [ next ]

                updateMessage message =
                    if message.id == change.messageId then
                        { message | reactions = updateReaction message.reactions }

                    else
                        message
            in
            ( { model | msg = List.map updateMessage model.msg }, Cmd.none )

        Err _ ->
            ( model, Cmd.none )


handleInviteCreated : E.Value -> Model -> ( Model, Cmd Msg )
handleInviteCreated val model =
    case ( D.decodeValue (D.field "code" D.string) val, D.decodeValue (D.field "url" D.string) val ) of
        ( Ok code, Ok url ) ->
            ( { model | modal = Just ("invite_result:" ++ code ++ ":" ++ url) }
            , Cmd.none
            )

        _ ->
            ( { model | modal = Just "invite_result:error:" }, Cmd.none )


serverDataDecoder : Decoder ServerData
serverDataDecoder =
    D.map4 (\server channels members categories -> { server = server, channels = channels, members = members, categories = categories })
        (D.field "server" decodeServer)
        (D.field "channels" (D.list decodeChannel))
        (D.field "members" (D.list decodeServerMember))
        (D.field "categories" (D.list decodeCategory) |> defaultValue [])


handleProfile : E.Value -> Model -> ( Model, Cmd Msg )
handleProfile val model =
    let
        userResult =
            D.decodeValue (D.field "user" decodeUser) val

        relResult =
            D.decodeValue (D.field "relationship" (D.field "status" D.string)) val

        blockedByMe =
            D.decodeValue (D.at [ "relationship", "blocked_by_me" ] D.bool) val |> Result.withDefault False

        rel =
            case relResult of
                Ok r ->
                    r

                Err _ ->
                    "none"
    in
    case userResult of
        Ok user ->
            ( { model | currentProfile = Just user, currentProfileRelationship = rel, currentProfileBlockedByMe = blockedByMe }, Cmd.none )

        Err _ ->
            ( model, Cmd.none )


handleInvitePreview : E.Value -> Model -> ( Model, Cmd Msg )
handleInvitePreview val model =
    case D.decodeValue invitePreviewDecoder val of
        Ok invite ->
            ( { model | invitePreview = Just invite }, Cmd.none )

        Err _ ->
            ( { model | invitePreview = Nothing, toast = Just "Could not load that Wire.", modal = Just "join_invite", modalUserIds = "" }, setHash "#" )


invitePreviewDecoder : Decoder InvitePreview
invitePreviewDecoder =
    D.oneOf
        [ invitePreviewRawDecoder
        , D.field "data" invitePreviewRawDecoder
        ]


invitePreviewRawDecoder : Decoder InvitePreview
invitePreviewRawDecoder =
    D.map8 InvitePreview
        (D.field "code" D.string)
        (D.field "server_id" D.int)
        (D.field "channel_id" (D.nullable D.int) |> defaultValue Nothing)
        (D.field "valid" D.bool |> defaultValue True)
        (D.oneOf [ D.at [ "server", "name" ] D.string, D.succeed "Server" ])
        (D.oneOf [ D.at [ "server", "description" ] (D.nullable D.string) |> D.map (Maybe.withDefault ""), D.succeed "" ])
        (D.oneOf [ D.at [ "server", "icon_url" ] (D.nullable D.string) |> D.map (Maybe.withDefault ""), D.succeed "" ])
        (D.oneOf [ D.at [ "server", "member_count" ] D.int, D.succeed 0 ])


handleCreateServer : E.Value -> Model -> ( Model, Cmd Msg )
handleCreateServer val model =
    case D.decodeValue (D.field "id" D.int) val of
        Ok id ->
            ( { model | serverName = "", serverDescription = "" }, setHash ("#server/" ++ String.fromInt id) )

        Err _ ->
            ( model, Cmd.none )


handleInviteJoin : E.Value -> Model -> ( Model, Cmd Msg )
handleInviteJoin val model =
    case D.decodeValue (D.field "server_id" D.int) val of
        Ok id ->
            ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), setHash ("#server/" ++ String.fromInt id) ] )

        Err _ ->
            ( model, Cmd.none )


dismissRouteNotifications : ActiveRoute -> List Notification -> List Notification
dismissRouteNotifications active notifs =
    case routeNotificationUrl active of
        Just url ->
            List.filter (\notification -> notification.url /= url) notifs

        Nothing ->
            notifs


captureEntryRead : Model -> List Message -> Model
captureEntryRead model messages =
    case model.active of
        DmView id ->
            if model.entryReadCaptured then
                model

            else
                case conversationReadMarker model id of
                    Nothing ->
                        if List.any (\message -> message.scope == "direct" && message.scopeId == id && message.id > 0) messages then
                            { model | entryReadCaptured = True, entryReadId = Nothing }

                        else
                            model

                    Just marker ->
                        let
                            loaded =
                                List.filter (\message -> message.scope == "direct" && message.scopeId == id && message.id > 0) messages

                            unread =
                                loaded
                                    |> List.filter (\message -> message.id > marker)
                                    |> List.sortBy .createdAt
                        in
                        case loaded of
                            [] ->
                                model

                            _ ->
                                case unread of
                                    [] ->
                                        { model | entryReadCaptured = True, entryReadId = Nothing }

                                    first :: rest ->
                                        let
                                            newest =
                                                List.foldl (\message age -> Basics.max age message.createdAt) first.createdAt rest

                                            clock =
                                                if model.serverTime > 0 then
                                                    model.serverTime

                                                else
                                                    newest

                                            settled =
                                                model.serverTime > 0 || newest - first.createdAt >= 25000
                                        in
                                        if not settled then
                                            model

                                        else if clock - first.createdAt >= 25000 then
                                            { model | entryReadCaptured = True, entryReadId = Just marker }

                                        else
                                            { model | entryReadCaptured = True, entryReadId = Nothing }

        _ ->
            model


conversationReadMarker : Model -> Int -> Maybe Int
conversationReadMarker model id =
    case List.filter (\conversation -> conversation.id == id) model.convs |> List.head of
        Just conversation ->
            if conversation.unread > 0 && conversation.lastReadMessageId > 0 then
                Just conversation.lastReadMessageId

            else
                Nothing

        Nothing ->
            Nothing


routeNotificationUrl : ActiveRoute -> Maybe String
routeNotificationUrl active =
    case active of
        DmView id ->
            Just ("#/dm/" ++ String.fromInt id)

        ChannelView id ->
            Just ("#/channel/" ++ String.fromInt id)

        ThreadView id ->
            Just ("#/t/" ++ String.fromInt id)

        _ ->
            Nothing


routeCmd : ActiveRoute -> Cmd Msg
routeCmd active =
    case active of
        Friends ->
            apiSend (encodeApiRequest (ApiGet "/friends"))

        Forums ->
            apiSend (encodeApiRequest (ApiGet "/forums"))

        ForumView id ->
            apiSend (encodeApiRequest (ApiGet ("/threads?forum_id=" ++ String.fromInt id)))

        ThreadView id ->
            apiSend (encodeApiRequest (ApiGet ("/thread/" ++ String.fromInt id)))

        DmView id ->
            Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet ("/messages?scope=direct&scope_id=" ++ String.fromInt id)))
                , apiSend (encodeApiRequest (ApiGet ("/conversation/" ++ String.fromInt id)))
                ]

        ChannelView id ->
            Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet ("/messages?scope=channel&scope_id=" ++ String.fromInt id)))
                , apiSend (encodeApiRequest (ApiGet ("/commands?channel_id=" ++ String.fromInt id)))
                ]

        ServerView id ->
            apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt id)))

        ProfileView id ->
            apiSend (encodeApiRequest (ApiGet ("/profile/" ++ String.fromInt id)))

        InviteView code ->
            if code /= "" then
                apiSend (encodeApiRequest (ApiGet ("/wires/" ++ code)))

            else
                Cmd.none

        SearchView q ->
            let
                encoded =
                    Url.percentEncode q
            in
            Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet ("/users?q=" ++ encoded)))
                , apiSend (encodeApiRequest (ApiGet ("/threads?q=" ++ encoded)))
                , apiSend (encodeApiRequest (ApiGet ("/search/messages?q=" ++ encoded ++ "&limit=30")))
                ]

        _ ->
            Cmd.none


routeSubCmd : ActiveRoute -> Cmd Msg
routeSubCmd active =
    case active of
        ForumView id ->
            wsSend (E.object [ ( "type", E.string "subscribe" ), ( "key", E.string ("forum:" ++ String.fromInt id) ) ])

        ThreadView id ->
            wsSend (E.object [ ( "type", E.string "subscribe" ), ( "key", E.string ("thread:" ++ String.fromInt id) ) ])

        DmView id ->
            wsSend (E.object [ ( "type", E.string "subscribe" ), ( "key", E.string ("direct:" ++ String.fromInt id) ) ])

        ServerView id ->
            wsSend (E.object [ ( "type", E.string "subscribe" ), ( "key", E.string ("server:" ++ String.fromInt id) ) ])

        ChannelView id ->
            wsSend (E.object [ ( "type", E.string "subscribe" ), ( "key", E.string ("channel:" ++ String.fromInt id) ) ])

        _ ->
            Cmd.none


updateVoiceMode : String -> Int -> VoiceState -> VoiceState
updateVoiceMode mode id voice =
    if voice.mode == Just mode && voice.id == Just id then
        voice

    else
        { voice
            | mode = Just mode
            , id = Just id
            , stream = Nothing
            , peers = Dict.empty
            , failedPeers = Dict.empty
            , users = Dict.empty
            , muted = False
            , deafened = False
            , mutedBeforeDeafen = False
            , screenShare = False
        }


clearVoice : VoiceState -> VoiceState
clearVoice voice =
    { voice
        | mode = Nothing
        , id = Nothing
        , stream = Nothing
        , screenShare = False
        , peers = Dict.empty
        , failedPeers = Dict.empty
        , users = Dict.empty
        , muted = False
        , deafened = False
        , mutedBeforeDeafen = False
    }


setRtcPeerConnected : String -> Int -> Int -> Bool -> Model -> Model
setRtcPeerConnected roomKind roomId userId connected model =
    let
        roomIsCurrent =
            model.voice.mode == Just roomKind && model.voice.id == Just roomId

        updateUser user =
            if user.userId == userId then
                { user
                    | connected = connected
                    , connectionFailed =
                        if connected then
                            False

                        else
                            user.connectionFailed
                }

            else
                user

        updateActive active =
            { active | users = List.map updateUser active.users }

        voice0 =
            model.voice

        nextVoice =
            if roomIsCurrent then
                { voice0
                    | peers = Dict.insert userId connected voice0.peers
                    , failedPeers =
                        if connected then
                            Dict.insert userId False voice0.failedPeers

                        else
                            voice0.failedPeers
                }

            else
                voice0

        nextOverlay =
            if roomIsCurrent && roomKind == "call" then
                Maybe.map updateActive model.callUI.active

            else
                model.callUI.active

        nextCalls =
            if roomIsCurrent && roomKind == "call" then
                Dict.update roomId (Maybe.map updateActive) model.activeCalls

            else
                model.activeCalls
    in
    { model
        | voice = nextVoice
        , activeCalls = nextCalls
        , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = nextOverlay }
    }


setRtcPeerFailed : String -> Int -> Int -> Bool -> Model -> Model
setRtcPeerFailed roomKind roomId userId failed model =
    let
        roomIsCurrent =
            model.voice.mode == Just roomKind && model.voice.id == Just roomId

        updateUser user =
            if user.userId == userId then
                { user
                    | connectionFailed = failed
                    , connected =
                        if failed then
                            False

                        else
                            user.connected
                }

            else
                user

        updateActive active =
            { active | users = List.map updateUser active.users }

        voice0 =
            model.voice

        nextVoice =
            if roomIsCurrent then
                { voice0
                    | failedPeers =
                        if failed then
                            Dict.insert userId True voice0.failedPeers

                        else
                            Dict.insert userId False voice0.failedPeers
                    , peers =
                        if failed then
                            Dict.insert userId False voice0.peers

                        else
                            voice0.peers
                }

            else
                voice0

        nextOverlay =
            if roomIsCurrent && roomKind == "call" then
                Maybe.map updateActive model.callUI.active

            else
                model.callUI.active

        nextCalls =
            if roomIsCurrent && roomKind == "call" then
                Dict.update roomId (Maybe.map updateActive) model.activeCalls

            else
                model.activeCalls
    in
    { model
        | voice = nextVoice
        , activeCalls = nextCalls
        , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = nextOverlay }
    }


mergeCallUserRtc : String -> Int -> List CallUser -> Model -> CallUser -> CallUser
mergeCallUserRtc roomKind roomId existingUsers model user =
    let
        previous =
            List.filter (\old -> old.userId == user.userId) existingUsers |> List.head

        previousConnected =
            Maybe.map .connected previous |> Maybe.withDefault user.connected

        previousFailed =
            Maybe.map .connectionFailed previous |> Maybe.withDefault user.connectionFailed

        roomIsCurrent =
            model.voice.mode == Just roomKind && model.voice.id == Just roomId

        connected =
            if roomIsCurrent then
                Dict.get user.userId model.voice.peers |> Maybe.withDefault previousConnected

            else
                previousConnected

        failed =
            if connected then
                False

            else if roomIsCurrent then
                Dict.get user.userId model.voice.failedPeers |> Maybe.withDefault previousFailed

            else
                previousFailed
    in
    { user | connected = connected, connectionFailed = failed }


isCurrentServer : Int -> Model -> Bool
isCurrentServer serverId model =
    model.currentServer
        |> Maybe.map (\d -> d.server.id == serverId)
        |> Maybe.withDefault False


refreshCurrentServer : Model -> Cmd Msg
refreshCurrentServer model =
    case model.currentServer of
        Just data ->
            apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt data.server.id)))

        Nothing ->
            Cmd.none


toggleMute : VoiceState -> VoiceState
toggleMute voice =
    { voice | muted = not voice.muted, mutedBeforeDeafen = not voice.muted }


toggleDeafen : VoiceState -> VoiceState
toggleDeafen voice =
    if voice.deafened then
        { voice | deafened = False, muted = voice.mutedBeforeDeafen }

    else
        { voice | deafened = True, mutedBeforeDeafen = voice.muted, muted = True }


matchingCommand : String -> List BotCommand -> Maybe ( BotCommand, String )
matchingCommand body commands =
    let
        trimmed =
            String.trim body

        pieces =
            String.words trimmed

        commandName =
            case pieces of
                first :: _ ->
                    if String.startsWith "/" first then
                        String.toLower (String.dropLeft 1 first)

                    else
                        ""

                [] ->
                    ""

        args =
            case pieces of
                _ :: rest ->
                    String.join " " rest

                [] ->
                    ""
    in
    if String.isEmpty commandName then
        Nothing

    else
        commands
            |> List.filter (\command -> String.toLower command.name == commandName)
            |> List.head
            |> Maybe.map (\command -> ( command, args ))


sendMessage : Model -> ( Model, Cmd Msg )
sendMessage model =
    let
        body =
            String.trim model.inputText

        replyField =
            Maybe.map .id model.replyTo

        payload =
            encodeMessage { body = body, replyToId = replyField }

        scrollToBottom =
            bridgeSend (E.object [ ( "tag", E.string "scroll_messages_to_bottom" ), ( "data", E.bool True ) ])
    in
    if String.isEmpty body then
        ( model, Cmd.none )

    else
        case model.active of
            DmView id ->
                let
                    path =
                        "/conversation/" ++ String.fromInt id ++ "/messages"

                    model2 =
                        appendOptimisticMessage "direct" id body model

                    lastMsgId =
                        case List.reverse model2.msg of
                            m :: _ ->
                                m.id

                            [] ->
                                -1
                in
                ( { model2 | pendingMessages = Dict.insert lastMsgId path model.pendingMessages, failedMsgIds = Set.remove lastMsgId model.failedMsgIds }
                , Cmd.batch [ apiSend (messageRequest lastMsgId path payload), scrollToBottom ]
                )

            ChannelView id ->
                case matchingCommand body model.availableCommands of
                    Just ( command, args ) ->
                        let
                            commandPayload =
                                E.object
                                    [ ( "channel_id", E.int id )
                                    , ( "args", E.string args )
                                    ]
                        in
                        -- Keep the draft until the server acknowledges the invocation. If
                        -- the request fails or times out, the user should never lose what
                        -- they typed. The response handler clears it on success.
                        ( model
                        , apiSend (encodeApiRequest (ApiPost ("/commands/" ++ command.name ++ "/invoke") (Just commandPayload)))
                        )

                    Nothing ->
                        let
                            path =
                                "/channels/" ++ String.fromInt id ++ "/messages"

                            model2 =
                                appendOptimisticMessage "channel" id body model

                            lastMsgId =
                                case List.reverse model2.msg of
                                    m :: _ ->
                                        m.id

                                    [] ->
                                        -1
                        in
                        ( { model2 | pendingMessages = Dict.insert lastMsgId path model.pendingMessages, failedMsgIds = Set.remove lastMsgId model.failedMsgIds }
                        , Cmd.batch [ apiSend (messageRequest lastMsgId path payload), scrollToBottom ]
                        )

            ThreadView id ->
                ( model, apiSend (encodeApiRequest (ApiPost ("/thread/" ++ String.fromInt id ++ "/replies") (Just (E.object [ ( "body", E.string body ) ])))) )

            _ ->
                ( model, Cmd.none )


toggleLastAttachmentSpoiler : String -> Maybe String
toggleLastAttachmentSpoiler source =
    let
        toggleLine line =
            let
                trimmed =
                    String.trim line

                isAttachment =
                    String.contains "](/api/files/" trimmed || String.contains "](/api/media/" trimmed
            in
            if not isAttachment then
                Nothing

            else if String.startsWith "||" trimmed && String.endsWith "||" trimmed && String.length trimmed > 4 then
                Just (String.dropRight 2 (String.dropLeft 2 trimmed))

            else
                Just ("||" ++ trimmed ++ "||")

        walk reversed prefix =
            case reversed of
                [] ->
                    Nothing

                line :: rest ->
                    case toggleLine line of
                        Just changed ->
                            Just (String.join "\n" (List.reverse (prefix ++ (changed :: rest))))

                        Nothing ->
                            walk rest (prefix ++ [ line ])
    in
    walk (List.reverse (String.lines source)) []


appendOptimisticMessage : String -> Int -> String -> Model -> Model
appendOptimisticMessage scope scopeId body model =
    case model.me of
        Just user ->
            let
                optimistic =
                    Message
                        model.nextMessageId
                        scope
                        scopeId
                        user.id
                        user.username
                        user.displayName
                        user.avatarUrl
                        body
                        "text"
                        (Maybe.map .id model.replyTo)
                        model.replyTo
                        (if model.serverTime > 0 then
                            model.serverTime

                         else
                            0
                        )
                        Nothing
                        Nothing
                        Nothing
                        ""
                        user.isBot
                        False
                        []
            in
            { model | msg = model.msg ++ [ optimistic ], inputText = "", replyTo = Nothing, drafts = Dict.remove (draftKeyFor model.active) model.drafts, outbox = Dict.insert optimistic.id optimistic model.outbox, nextMessageId = model.nextMessageId - 1 }

        Nothing ->
            model




handleWsEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleWsEvent val model =
    case D.decodeValue wsEventDecoder val of
        Ok ( "message_created", ev ) ->
            handleMessageCreated ev model

        Ok ( "message_updated", ev ) ->
            handleMessageUpdatedEvent ev model

        Ok ( "message_deleted", ev ) ->
            handleMessageDeleted ev model

        Ok ( "message_reaction_changed", ev ) ->
            handleReactionChange ev model

        Ok ( "message_pin_changed", ev ) ->
            handleMessagePinChanged ev model

        Ok ( "direct_message", _ ) ->
            handleNotifiedMessage val model

        Ok ( "channel_message", _ ) ->
            handleNotifiedMessage val model

        Ok ( "mention", _ ) ->
            handleMention val model

        Ok ( "notification", ev ) ->
            handleNotificationEvent ev model

        Ok ( "friend_request", _ ) ->
            ( model, bridgeSend (E.object [ ( "tag", E.string "silent_sync" ), ( "data", E.null ) ]) )

        Ok ( "friend_accept", _ ) ->
            ( model, bridgeSend (E.object [ ( "tag", E.string "silent_sync" ), ( "data", E.null ) ]) )

        Ok ( "user_identity_updated", _ ) ->
            ( model
            , Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet "/me"))
                , bridgeSend (E.object [ ( "tag", E.string "silent_sync" ), ( "data", E.null ) ])
                , routeCmd model.active
                ]
            )

        Ok ( "conversation_created", _ ) ->
            ( model, bridgeSend (E.object [ ( "tag", E.string "silent_sync" ), ( "data", E.null ) ]) )

        Ok ( "conversation_members_added", ev ) ->
            handleConversationStructureEvent ev model

        Ok ( "conversation_members_changed", ev ) ->
            handleConversationStructureEvent ev model

        Ok ( "conversation_member_removed", ev ) ->
            handleConversationStructureEvent ev model

        Ok ( "conversation_updated", ev ) ->
            handleConversationStructureEvent ev model

        Ok ( "server_updated", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "server_roles_updated", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "server_member_roles_updated", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "server_member_removed", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "server_member_profile_updated", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "channel_created", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "channel_updated", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "member_joined", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "thread_created", ev ) ->
            handleThreadListEvent ev model

        Ok ( "thread_updated", ev ) ->
            handleThreadRefreshEvent ev model

        Ok ( "thread_reply_updated", ev ) ->
            handleThreadRefreshEvent ev model

        Ok ( "thread_reply_deleted", ev ) ->
            handleThreadRefreshEvent ev model

        Ok ( "thread_deleted", ev ) ->
            handleThreadDeletedEvent ev model

        Ok ( "forum_deleted", ev ) ->
            handleForumDeletedEvent ev model

        Ok ( "thread_reply", ev ) ->
            handleThreadReplyEvent ev model

        Ok ( "access_revoked", ev ) ->
            handleAccessRevoked ev model

        Ok ( "call_incoming", ev ) ->
            handleCallIncoming ev model

        Ok ( "call_ringing", ev ) ->
            case D.decodeValue callOutgoingDecoder ev of
                Ok out ->
                    let
                        active =
                            case model.callUI.active of
                                Just current ->
                                    if current.conversationId == out.convId then
                                        current

                                    else
                                        { conversationId = out.convId, users = [], startTime = model.serverTime, expanded = False }

                                Nothing ->
                                    { conversationId = out.convId, users = [], startTime = model.serverTime, expanded = False }
                    in
                    ( { model
                        | callUI =
                            { incoming = Nothing
                            , outgoing = Just { conversationId = out.convId, userId = 0, displayName = out.displayName, avatarUrl = out.avatarUrl }
                            , active = Just active
                            }
                        , activeCalls = Dict.insert out.convId active model.activeCalls
                        , callMode = Ringing
                        , voice = updateVoiceMode "call" out.convId model.voice
                      }
                    , playOutgoingRingtone True
                    )

                Err _ ->
                    ( { model | callUI = { incoming = Nothing, outgoing = model.callUI.outgoing, active = model.callUI.active }, callMode = Ringing }, playOutgoingRingtone True )

        Ok ( "call_accepted", ev ) ->
            case D.decodeValue callAcceptedDecoder ev of
                Ok accepted ->
                    let
                        rawPeer =
                            { userId = accepted.userId
                            , displayName = accepted.displayName
                            , avatarUrl = accepted.avatarUrl
                            , muted = False
                            , deafened = False
                            , connected = False
                            , connectionFailed = False
                            , reconnecting = False
                            , screen = False
                            , screenAudio = False
                            }

                        peer =
                            mergeCallUserRtc "call" accepted.convId [] model rawPeer

                        addPeer users =
                            if List.any (\u -> u.userId == peer.userId) users then
                                users

                            else
                                users ++ [ peer ]

                        active =
                            case model.callUI.active of
                                Just a ->
                                    Just
                                        { a
                                            | conversationId =
                                                if a.conversationId == 0 then
                                                    accepted.convId

                                                else
                                                    a.conversationId
                                            , users = addPeer a.users
                                        }

                                Nothing ->
                                    Just { conversationId = accepted.convId, users = [ peer ], startTime = model.serverTime, expanded = False }
                    in
                    let
                        nextCalls =
                            case active of
                                Just call ->
                                    Dict.insert accepted.convId call model.activeCalls

                                Nothing ->
                                    model.activeCalls
                    in
                    ( { model
                        | callUI = { incoming = Nothing, outgoing = Nothing, active = active }
                        , activeCalls = nextCalls
                        , callMode = Connected
                        , voice = updateVoiceMode "call" accepted.convId model.voice
                      }
                    , Cmd.batch [ playRingtone False, playOutgoingRingtone False ]
                    )

                Err _ ->
                    ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = model.callUI.active }, callMode = Connected }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )

        Ok ( "call_missed", ev ) ->
            let
                conversationId =
                    D.decodeValue (D.field "conversation_id" D.int) ev |> Result.withDefault 0

                callerId =
                    D.decodeValue (D.field "from_user_id" D.int) ev |> Result.withDefault 0

                callerName =
                    D.decodeValue (D.at [ "profile", "display_name" ] D.string) ev |> Result.withDefault "Someone"

                fromMe =
                    Maybe.map .id model.me == Just callerId

                message =
                    if fromMe then
                        "No answer"

                    else
                        "Missed call from " ++ callerName

                nextVoice =
                    if model.voice.mode == Just "call" && model.voice.id == Just conversationId then
                        clearVoice model.voice

                    else
                        model.voice
            in
            ( { model
                | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }
                , activeCalls = Dict.remove conversationId model.activeCalls
                , callMode = Idle
                , voice = nextVoice
                , toast = Just message
              }
            , Cmd.batch
                [ playRingtone False
                , playOutgoingRingtone False
                , Process.sleep 5000 |> Task.perform (\_ -> DismissToast)
                ]
            )

        Ok ( "call_declined", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )

        Ok ( "call_cancelled", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )

        Ok ( "call_ended", ev ) ->
            case D.decodeValue (D.field "reason" D.string) ev of
                Ok "accepted" ->
                    ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = model.callUI.active } }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )

                _ ->
                    let
                        cid =
                            case D.decodeValue (D.field "conversation_id" D.int) ev of
                                Ok id ->
                                    id

                                Err _ ->
                                    0

                        joinedCall =
                            isJoinedCall cid model
                    in
                    if joinedCall then
                        ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = model.callUI.active } }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )

                    else
                        ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle, voice = clearVoice model.voice }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )

        Ok ( "call_state", ev ) ->
            case D.decodeValue callStateDecoder ev of
                Ok ( cid, users ) ->
                    if not (isJoinedCall cid model) then
                        ( model, Cmd.none )

                    else
                        let
                            existing =
                                Maybe.andThen
                                    (\a ->
                                        if a.conversationId == cid then
                                            Just a

                                        else
                                            Nothing
                                    )
                                    model.callUI.active

                            mappedUsers =
                                Dict.get cid model.activeCalls |> Maybe.map .users |> Maybe.withDefault []

                            existingUsers =
                                Maybe.withDefault [] (Maybe.map .users existing) ++ mappedUsers

                            safeUsers =
                                if List.isEmpty users && isJoinedCall cid model then
                                    Maybe.withDefault [] (Maybe.map .users existing)

                                else
                                    List.map (mergeCallUserRtc "call" cid existingUsers model) users

                            active =
                                { conversationId = cid
                                , users = safeUsers
                                , startTime = Maybe.withDefault model.serverTime (Maybe.map .startTime existing)
                                , expanded = Maybe.withDefault False (Maybe.map .expanded existing)
                                }
                        in
                        ( { model
                            | activeCalls = Dict.insert cid active model.activeCalls
                            , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = Just active }
                          }
                        , Cmd.none
                        )

                Err _ ->
                    ( model, Cmd.none )

        Ok ( "call_presence", ev ) ->
            handleCallPresence ev model

        Ok ( "call_peer_joined", ev ) ->
            case ( D.decodeValue (D.field "conversation_id" D.int) ev, D.decodeValue callPeerJoinedDecoder ev ) of
                ( Ok cid, Ok peer ) ->
                    let
                        knownPeer =
                            mergeCallUserRtc "call" cid [] model peer

                        addUser users =
                            if List.any (\u -> u.userId == knownPeer.userId) users then
                                users

                            else
                                users ++ [ knownPeer ]

                        updateActive a =
                            { a | users = addUser a.users }
                    in
                    if isJoinedCall cid model then
                        let
                            nextOverlay =
                                Maybe.map updateActive model.callUI.active

                            nextCalls =
                                case nextOverlay of
                                    Just active ->
                                        Dict.insert cid active model.activeCalls

                                    Nothing ->
                                        Dict.update cid (Maybe.map updateActive) model.activeCalls
                        in
                        ( { model
                            | activeCalls = nextCalls
                            , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = nextOverlay }
                          }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        Ok ( "call_peer_left", ev ) ->
            case ( D.decodeValue (D.field "conversation_id" D.int) ev, D.decodeValue (D.field "user_id" D.int) ev ) of
                ( Ok cid, Ok uid ) ->
                    let
                        removeUser users =
                            List.filter (\u -> u.userId /= uid) users

                        updateActive a =
                            { a | users = removeUser a.users }
                    in
                    if isJoinedCall cid model then
                        let
                            nextOverlay =
                                Maybe.map updateActive model.callUI.active

                            nextCalls =
                                case nextOverlay of
                                    Just active ->
                                        Dict.insert cid active model.activeCalls

                                    Nothing ->
                                        Dict.update cid (Maybe.map updateActive) model.activeCalls

                            voice0 =
                                model.voice

                            nextVoice =
                                { voice0
                                    | peers = Dict.remove uid voice0.peers
                                    , failedPeers = Dict.remove uid voice0.failedPeers
                                }
                        in
                        ( { model
                            | activeCalls = nextCalls
                            , voice = nextVoice
                            , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = nextOverlay }
                          }
                        , Cmd.none
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        Ok ( "call_signal", ev ) ->
            ( model, Cmd.none )

        Ok ( "call_superseded", ev ) ->
            clearSupersededCall ev model

        Ok ( "call_ejected", ev ) ->
            clearSupersededCall ev model

        Ok ( "voice_state", ev ) ->
            case D.decodeValue voiceStateDecoder ev of
                Ok ( channelId, users ) ->
                    let
                        userDict =
                            Dict.fromList (List.map (\u -> ( u.userId, u )) users)

                        voice0 =
                            model.voice
                    in
                    -- Nothing means we left already; this event is old news.
                    case voice0.mode of
                        Just "voice" ->
                            if voice0.id == Just channelId then
                                ( { model | voice = { voice0 | users = userDict }, callMode = InCall }, Cmd.none )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        Ok ( "voice_peer_left", ev ) ->
            case D.decodeValue (D.field "user_id" D.int) ev of
                Ok uid ->
                    let
                        voice0 =
                            model.voice
                    in
                    ( { model
                        | voice =
                            { voice0
                                | users = Dict.remove uid voice0.users
                                , peers = Dict.remove uid voice0.peers
                                , failedPeers = Dict.remove uid voice0.failedPeers
                            }
                      }
                    , Cmd.none
                    )

                Err _ ->
                    ( model, Cmd.none )

        Ok ( "voice_user_joined", ev ) ->
            ( model, Cmd.none )

        Ok ( "voice_user_left", ev ) ->
            ( model, Cmd.none )

        Ok ( "voice_signal", ev ) ->
            ( model, Cmd.none )

        Ok ( "voice_superseded", _ ) ->
            ( { model | voice = clearVoice model.voice, callMode = Idle }, Cmd.none )

        Ok ( "voice_ejected", _ ) ->
            ( { model | voice = clearVoice model.voice, callMode = Idle }, Cmd.none )

        Ok ( "presence_state", ev ) ->
            case D.decodeValue (D.field "statuses" (D.dict D.string)) ev of
                Ok statuses ->
                    ( { model | userStatuses = statuses }, Cmd.none )

                Err _ ->
                    case D.decodeValue (D.field "online" (D.list D.int)) ev of
                        Ok ids ->
                            ( { model | userStatuses = Dict.fromList (List.map (\id -> ( String.fromInt id, "online" )) ids) }, Cmd.none )

                        Err _ ->
                            ( model, Cmd.none )

        Ok ( "presence_online", ev ) ->
            case D.decodeValue (D.map2 (\uid s -> ( uid, s )) (D.field "user_id" D.int) (D.field "status" D.string |> D.maybe |> D.map (Maybe.withDefault "online"))) ev of
                Ok ( uid, status ) ->
                    ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        Ok ( "presence_offline", ev ) ->
            case D.decodeValue (D.field "user_id" D.int) ev of
                Ok uid ->
                    ( { model | userStatuses = Dict.remove (String.fromInt uid) model.userStatuses }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )

        Ok ( "error", ev ) ->
            let
                reason =
                    D.decodeValue (D.field "error" D.string) ev |> Result.withDefault "unknown"

                message =
                    case reason of
                        "rate_limited" ->
                            "You're doing that too quickly. Try again in a moment."

                        "too_many_subscriptions" ->
                            "Too many live updates are open. Close a few views and try again."

                        "forbidden" ->
                            "You don't have permission to do that."

                        "unavailable" ->
                            "That service is temporarily unavailable. Try again."

                        _ ->
                            "Something went wrong. Please try again."
            in
            ( model
            , bridgeSend
                (E.object
                    [ ( "tag", E.string "toast" )
                    , ( "data", E.string message )
                    ]
                )
            )

        Ok ( "category_created", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "category_updated", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "category_deleted", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "categories_reordered", ev ) ->
            handleServerStructureEvent ev model

        Ok ( "channel_moved", ev ) ->
            handleServerStructureEvent ev model

        _ ->
            ( model, Cmd.none )


handleServerStructureEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleServerStructureEvent ev model =
    case D.decodeValue (D.field "server_id" D.int) ev of
        Ok serverId ->
            let
                refreshServer =
                    if isCurrentServer serverId model then
                        apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt serverId)))

                    else
                        Cmd.none
            in
            ( { model | serverCache = Dict.remove serverId model.serverCache }
            , Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                , refreshServer
                ]
            )

        Err _ ->
            ( model, Cmd.none )


handleMessagePinChanged : E.Value -> Model -> ( Model, Cmd Msg )
handleMessagePinChanged ev model =
    case D.decodeValue (D.map2 Tuple.pair (D.field "message_id" D.int) (D.field "pinned" D.bool)) ev of
        Ok ( messageId, pinned ) ->
            let
                updatePinned message =
                    if message.id == messageId then
                        { message | pinned = pinned }

                    else
                        message

                maybeMessage =
                    findMessage messageId model.msg |> Maybe.map updatePinned

                nextPins =
                    if pinned then
                        case maybeMessage of
                            Just message ->
                                message :: List.filter (\item -> item.id /= messageId) model.pinnedMessages

                            Nothing ->
                                model.pinnedMessages

                    else
                        List.filter (\item -> item.id /= messageId) model.pinnedMessages
            in
            ( { model | msg = List.map updatePinned model.msg, pinnedMessages = nextPins }, Cmd.none )

        Err _ ->
            ( model, Cmd.none )


handleConversationStructureEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleConversationStructureEvent ev model =
    case D.decodeValue (D.field "conversation_id" D.int) ev of
        Ok conversationId ->
            ( model
            , Cmd.batch
                [ apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                , apiSend (encodeApiRequest (ApiGet ("/conversation/" ++ String.fromInt conversationId)))
                ]
            )

        Err _ ->
            ( model, Cmd.none )


handleThreadListEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleThreadListEvent ev model =
    case ( D.decodeValue (D.field "forum_id" D.int) ev, model.active ) of
        ( Ok forumId, ForumView currentId ) ->
            if forumId == currentId then
                ( model, routeCmd model.active )

            else
                ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


handleThreadDeletedEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleThreadDeletedEvent ev model =
    case ( D.decodeValue (D.field "forum_id" D.int) ev, D.decodeValue (D.field "thread_id" D.int) ev ) of
        ( Ok forumId, Ok threadId ) ->
            case model.active of
                ThreadView currentId ->
                    if currentId == threadId then
                        ( model, setHash ("#f/" ++ String.fromInt forumId) )

                    else
                        ( model, Cmd.none )

                ForumView currentId ->
                    if currentId == forumId then
                        ( model, routeCmd model.active )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        _ ->
            ( model, Cmd.none )


handleForumDeletedEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleForumDeletedEvent ev model =
    case ( D.decodeValue (D.field "forum_id" D.int) ev, model.active ) of
        ( Ok forumId, ForumView currentId ) ->
            if forumId == currentId then
                ( model, setHash "#forums" )

            else
                ( model, Cmd.none )

        ( Ok _, ThreadView _ ) ->
            ( model, setHash "#forums" )

        _ ->
            ( model, Cmd.none )


handleThreadReplyEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleThreadReplyEvent ev model =
    case D.decodeValue (D.field "thread_id" D.int) ev of
        Ok threadId ->
            case model.active of
                ThreadView currentId ->
                    if currentId /= threadId then
                        ( model, Cmd.none )

                    else
                        case D.decodeValue (D.field "reply" decodeReply) ev of
                            Ok reply ->
                                if List.any (\existing -> existing.id == reply.id) model.replies then
                                    ( model, Cmd.none )

                                else
                                    ( { model | replies = model.replies ++ [ reply ] }, Cmd.none )

                            Err _ ->
                                ( model, routeCmd model.active )

                _ ->
                    ( model, Cmd.none )

        Err _ ->
            ( model, Cmd.none )


handleThreadRefreshEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleThreadRefreshEvent ev model =
    case D.decodeValue (D.field "thread_id" D.int) ev of
        Ok threadId ->
            case model.active of
                ThreadView currentId ->
                    if currentId == threadId then
                        ( model, routeCmd model.active )

                    else
                        ( model, Cmd.none )

                ForumView _ ->
                    handleThreadListEvent ev model

                _ ->
                    ( model, Cmd.none )

        Err _ ->
            ( model, Cmd.none )


handleAccessRevoked : E.Value -> Model -> ( Model, Cmd Msg )
handleAccessRevoked ev model =
    let
        scope =
            D.decodeValue (D.field "scope" D.string) ev |> Result.withDefault ""

        serverId =
            D.decodeValue (D.field "server_id" D.int) ev |> Result.toMaybe

        conversationId =
            D.decodeValue (D.field "conversation_id" D.int) ev |> Result.toMaybe

        channelIds =
            D.decodeValue (D.field "channel_ids" (D.list D.int)) ev |> Result.withDefault []

        activeRevoked =
            case ( scope, model.active ) of
                ( "server", ServerView sid ) ->
                    serverId == Just sid

                ( "server", ChannelView cid ) ->
                    List.member cid channelIds

                ( "server", VoiceChannelView cid ) ->
                    List.member cid channelIds

                ( "direct", DmView cid ) ->
                    conversationId == Just cid

                _ ->
                    False

        nextModel =
            case serverId of
                Just sid ->
                    let
                        currentMatches =
                            model.currentServer
                                |> Maybe.map (\data -> data.server.id == sid)
                                |> Maybe.withDefault False

                        profileMatches =
                            model.currentServerProfile
                                |> Maybe.map (\profile -> profile.serverId == sid)
                                |> Maybe.withDefault False
                    in
                    { model
                        | servers = List.filter (\server -> server.id /= sid) model.servers
                        , serverCache = Dict.remove sid model.serverCache
                        , currentServer =
                            if currentMatches then
                                Nothing

                            else
                                model.currentServer
                        , currentServerProfile =
                            if profileMatches then
                                Nothing

                            else
                                model.currentServerProfile
                        , modal =
                            if profileMatches then
                                Nothing

                            else
                                model.modal
                    }

                Nothing ->
                    model

        destination =
            if activeRevoked then
                if scope == "server" then
                    setHash "#"

                else
                    setHash "#dms"

            else
                Cmd.none
    in
    ( nextModel
    , Cmd.batch
        [ apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
        , destination
        ]
    )


clearSupersededCall : E.Value -> Model -> ( Model, Cmd Msg )
clearSupersededCall ev model =
    let
        conversationId =
            D.decodeValue (D.field "conversation_id" D.int) ev |> Result.withDefault 0
    in
    ( { model
        | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }
        , activeCalls = Dict.remove conversationId model.activeCalls
        , callMode = Idle
        , voice = clearVoice model.voice
      }
    , Cmd.batch [ playRingtone False, playOutgoingRingtone False ]
    )


wsEventDecoder : Decoder ( String, E.Value )
wsEventDecoder =
    D.map2 Tuple.pair
        (D.field "type" D.string)
        D.value


handleMessageCreated : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageCreated ev model =
    case D.decodeValue (D.field "message" decodeMessage) ev of
        Ok message ->
            let
                model1 =
                    absorbOptimisticEchoes [ message ] model

                alreadyPresent =
                    List.any (\existing -> existing.id == message.id) model1.msg

                fromMe =
                    Maybe.map .id model1.me == Just message.userId

                notification =
                    if fromMe then
                        Cmd.none

                    else
                        playNotification model.soundEnabled
            in
            if alreadyPresent then
                ( model1, Cmd.none )

            else if messageApplies model1.active message && model1.messageContextMode then
                ( { model1
                    | convs = List.map (updateConversationPreview message) model1.convs
                    , toast =
                        if fromMe then
                            model1.toast

                        else
                            Just "New messages are available. Return to Latest to see them."
                  }
                , notification
                )

            else if messageApplies model1.active message then
                ( { model1
                    | msg = List.filter (\m -> m.id /= message.id) model1.msg ++ [ message ]
                    , convs = List.map (updateConversationPreview message) model1.convs
                  }
                , Cmd.batch
                    [ notification
                    , bridgeSend (E.object [ ( "tag", E.string "scroll_messages_to_bottom" ), ( "data", E.null ) ])
                    ]
                )

            else
                ( model1, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), notification ] )

        Err _ ->
            ( model, Cmd.none )


handleNotifiedMessage : E.Value -> Model -> ( Model, Cmd Msg )
handleNotifiedMessage ev model =
    case D.decodeValue (D.field "message" decodeMessage) ev of
        Ok message ->
            let
                model1 =
                    absorbOptimisticEchoes [ message ] model

                alreadyPresent =
                    List.any (\existing -> existing.id == message.id) model1.msg
            in
            if alreadyPresent then
                ( model1, Cmd.none )

            else if messageApplies model1.active message && model1.messageContextMode then
                ( { model1
                    | convs = List.map (updateConversationPreview message) model1.convs
                    , toast = Just "New messages are available. Return to Latest to see them."
                  }
                , playNotification model1.soundEnabled
                )

            else if messageApplies model1.active message then
                ( { model1
                    | msg = List.filter (\m -> m.id /= message.id) model1.msg ++ [ message ]
                    , convs = List.map (updateConversationPreview message) model1.convs
                  }
                , Cmd.batch
                    [ playNotification model.soundEnabled
                    , bridgeSend (E.object [ ( "tag", E.string "scroll_messages_to_bottom" ), ( "data", E.null ) ])
                    ]
                )

            else
                ( model1, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), playNotification model1.soundEnabled ] )

        Err _ ->
            ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), playNotification model.soundEnabled ] )


notificationEventDecoder : Decoder { kind : String, body : String, url : String, messageId : Int, emoji : String }
notificationEventDecoder =
    D.map5
        (\kind body url messageId emoji -> { kind = kind, body = body, url = url, messageId = messageId, emoji = emoji })
        (D.field "kind" D.string |> defaultValue "notification")
        (D.field "body" D.string |> defaultValue "New activity")
        (D.field "url" D.string |> defaultValue "#notifications")
        (D.field "message_id" D.int |> defaultValue 0)
        (D.field "emoji" D.string |> defaultValue "")


handleNotificationEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleNotificationEvent ev model =
    let
        decoded =
            D.decodeValue (D.oneOf [ D.field "event" notificationEventDecoder, notificationEventDecoder ]) ev

        sync =
            bridgeSend (E.object [ ( "tag", E.string "silent_sync" ), ( "data", E.null ) ])
    in
    case decoded of
        Ok event ->
            if event.kind == "message_reaction" then
                let
                    reactionTitle =
                        if String.isEmpty event.emoji then
                            "New reaction"

                        else
                            event.emoji ++ " New reaction"

                    tagText =
                        if event.messageId > 0 then
                            "reaction:" ++ String.fromInt event.messageId ++ ":" ++ event.emoji

                        else
                            "reaction:" ++ event.url ++ ":" ++ event.emoji

                    visibleToast =
                        if model.pageVisible then
                            Just event.body

                        else
                            model.toast

                    dismiss =
                        if model.pageVisible then
                            Process.sleep 4500 |> Task.perform (\_ -> DismissToast)

                        else
                            Cmd.none

                    desktop =
                        if model.pageVisible then
                            Cmd.none

                        else
                            notify
                                (E.object
                                    [ ( "title", E.string reactionTitle )
                                    , ( "body", E.string event.body )
                                    , ( "url", E.string event.url )
                                    , ( "tag", E.string tagText )
                                    ]
                                )
                in
                ( { model | toast = visibleToast }
                , Cmd.batch [ sync, playNotification model.soundEnabled, desktop, dismiss ]
                )

            else
                ( model, sync )

        Err _ ->
            ( model, sync )


handleMention : E.Value -> Model -> ( Model, Cmd Msg )
handleMention ev model =
    case D.decodeValue (D.field "message" decodeMessage) ev of
        Ok message ->
            let
                fromMe =
                    Maybe.map .id model.me == Just message.userId

                alreadyPresent =
                    List.any (\existing -> existing.id == message.id) model.msg

                applies =
                    messageApplies model.active message

                snippet =
                    String.filter (\c -> c /= '\n') message.body |> String.left 160

                title =
                    if fromMe then
                        "You were mentioned"

                    else
                        message.displayName ++ " mentioned you"
            in
            if fromMe || alreadyPresent then
                ( model
                , if applies then
                    Cmd.batch
                        [ playMention model.soundEnabled
                        , bridgeSend (E.object [ ( "tag", E.string "scroll_messages_to_bottom" ), ( "data", E.null ) ])
                        ]

                  else
                    Cmd.none
                )

            else if applies then
                ( { model
                    | msg = List.filter (\m -> m.id /= message.id) model.msg ++ [ message ]
                    , convs = List.map (updateConversationPreview message) model.convs
                  }
                , Cmd.batch
                    [ playMention model.soundEnabled
                    , bridgeSend (E.object [ ( "tag", E.string "scroll_messages_to_bottom" ), ( "data", E.null ) ])
                    ]
                )

            else
                ( { model
                    | mentionHints = Set.insert (mentionHintKey message) model.mentionHints
                    , toast = Just (title ++ ": “" ++ snippet ++ "”")
                  }
                , Cmd.batch
                    [ Process.sleep 5000 |> Task.perform (\_ -> DismissToast)
                    , playMention model.soundEnabled
                    , notify
                        (E.object
                            [ ( "title", E.string title )
                            , ( "body", E.string snippet )
                            , ( "url", E.string (mentionUrl message) )
                            , ( "tag", E.string ("mention:" ++ String.fromInt message.id) )
                            ]
                        )
                    , apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                    ]
                )

        Err _ ->
            case D.decodeValue (D.map2 Tuple.pair (D.field "thread_id" D.int) (D.field "body" D.string)) ev of
                Ok ( threadId, threadBody ) ->
                    let
                        snippet =
                            String.filter (\c -> c /= '\n') threadBody |> String.left 160
                    in
                    ( { model | toast = Just ("You were mentioned in a discussion: “" ++ snippet ++ "”") }
                    , Cmd.batch
                        [ Process.sleep 5000 |> Task.perform (\_ -> DismissToast)
                        , playMention model.soundEnabled
                        , notify
                            (E.object
                                [ ( "title", E.string "You were mentioned in a discussion" )
                                , ( "body", E.string snippet )
                                , ( "url", E.string ("#t/" ++ String.fromInt threadId) )
                                , ( "tag", E.string ("mention-thread:" ++ String.fromInt threadId) )
                                ]
                            )
                        , apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                        ]
                    )

                Err _ ->
                    ( model, Cmd.none )


mentionHintKey : Message -> String
mentionHintKey message =
    if message.scope == "direct" then
        "dm:" ++ String.fromInt message.scopeId

    else
        "channel:" ++ String.fromInt message.scopeId


mentionUrl : Message -> String
mentionUrl message =
    if message.scope == "direct" then
        "#dm/" ++ String.fromInt message.scopeId

    else
        "#channel/" ++ String.fromInt message.scopeId


handleCallPresence : E.Value -> Model -> ( Model, Cmd Msg )
handleCallPresence ev model =
    case D.decodeValue callPresenceDecoder ev of
        Ok ( cid, activeNow, users ) ->
            let
                existing =
                    case Dict.get cid model.activeCalls of
                        Just call ->
                            Just call

                        Nothing ->
                            Maybe.andThen
                                (\call ->
                                    if call.conversationId == cid then
                                        Just call

                                    else
                                        Nothing
                                )
                                model.callUI.active

                overlayUsers =
                    Maybe.andThen
                        (\call ->
                            if call.conversationId == cid then
                                Just call.users

                            else
                                Nothing
                        )
                        model.callUI.active
                        |> Maybe.withDefault []

                existingUsers =
                    Maybe.withDefault [] (Maybe.map .users existing) ++ overlayUsers

                mergeConnected user =
                    mergeCallUserRtc "call" cid existingUsers model user

                nextCall =
                    { conversationId = cid
                    , users = List.map mergeConnected users
                    , startTime = Maybe.withDefault model.serverTime (Maybe.map .startTime existing)
                    , expanded = Maybe.withDefault False (Maybe.map .expanded existing)
                    }

                nextCalls =
                    if activeNow then
                        Dict.insert cid nextCall model.activeCalls

                    else
                        Dict.remove cid model.activeCalls

                nextOverlay =
                    if activeNow && isJoinedCall cid model then
                        Just nextCall

                    else
                        case model.callUI.active of
                            Just call ->
                                if not activeNow && call.conversationId == cid && not (isJoinedCall cid model) then
                                    Nothing

                                else
                                    Just call

                            Nothing ->
                                Nothing
            in
            if activeNow then
                ( { model
                    | activeCalls = nextCalls
                    , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = nextOverlay }
                  }
                , Cmd.none
                )

            else if isJoinedCall cid model then
                ( { model | activeCalls = nextCalls }, Cmd.none )

            else
                ( { model
                    | activeCalls = nextCalls
                    , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = nextOverlay }
                  }
                , Cmd.none
                )

        Err _ ->
            ( model, Cmd.none )


handleMessageUpdatedEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageUpdatedEvent ev model =
    case D.decodeValue (D.field "message" decodeMessage) ev of
        Ok message ->
            handleMessageUpdated message model

        Err _ ->
            ( model, Cmd.none )


handleMessageUpdatedValue : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageUpdatedValue val model =
    case D.decodeValue decodeMessage val of
        Ok message ->
            handleMessageUpdated message model

        Err _ ->
            ( model, routeCmd model.active )


handleMessageUpdated : Message -> Model -> ( Model, Cmd Msg )
handleMessageUpdated message model =
    let
        updateOne existing =
            if existing.id == message.id then
                { message | reactions = existing.reactions }

            else
                existing

    in
    ( { model
        | msg = List.map updateOne model.msg
        , convs =
            List.map
                (\conversation ->
                    if conversation.lastMessageId == Just message.id then
                        updateConversationPreview message conversation

                    else
                        conversation
                )
                model.convs
      }
    , Cmd.none
    )


updateConversationPreview : Message -> Conversation -> Conversation
updateConversationPreview message conversation =
    if message.scope == "direct" && conversation.id == message.scopeId then
        { conversation
            | lastBody = Just message.body
            , lastMessageId = Just message.id
            , lastSenderId = message.userId
            , lastSenderName = message.displayName
            , lastSenderUsername = message.username
            , updatedAt = Basics.max conversation.updatedAt message.createdAt
        }

    else
        conversation


handleMessageDeleted : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageDeleted ev model =
    case D.decodeValue (D.field "message_id" D.int) ev of
        Ok messageId ->
            let
                deletedLatest =
                    List.any (\conversation -> conversation.lastMessageId == Just messageId) model.convs

                nextEditingId =
                    if model.editingMessageId == Just messageId then
                        Nothing

                    else
                        model.editingMessageId
            in
            ( { model
                | msg = List.filter (\m -> m.id /= messageId) model.msg
                , pinnedMessages = List.filter (\m -> m.id /= messageId) model.pinnedMessages
                , editingMessageId = nextEditingId
                , editingMessageText = if nextEditingId == Nothing then "" else model.editingMessageText
              }
            , if deletedLatest then
                apiSend (encodeApiRequest (ApiGet "/sync?since=0"))

              else
                Cmd.none
            )

        Err _ ->
            ( model, Cmd.none )


messageApplies : ActiveRoute -> Message -> Bool
messageApplies active message =
    case active of
        DmView id ->
            message.scope == "direct" && message.scopeId == id

        ChannelView id ->
            message.scope == "channel" && message.scopeId == id

        _ ->
            False


handleCallIncoming : E.Value -> Model -> ( Model, Cmd Msg )
handleCallIncoming ev model =
    case D.decodeValue callIncomingDecoder ev of
        Ok { convId, userId, displayName, avatarUrl } ->
            ( { model
                | callUI =
                    { incoming =
                        Just
                            { conversationId = convId
                            , userId = userId
                            , displayName = displayName
                            , avatarUrl = avatarUrl
                            }
                    , outgoing = Nothing
                    , active = model.callUI.active
                    }
                , callMode = Ringing
              }
            , bridgeSend
                (E.object
                    [ ( "tag", E.string "play_ringtone" )
                    , ( "data", E.null )
                    ]
                )
            )

        Err _ ->
            ( model, Cmd.none )


callIncomingDecoder : Decoder { convId : Int, userId : Int, displayName : String, avatarUrl : String }
callIncomingDecoder =
    D.map4 (\c u d a -> { convId = c, userId = u, displayName = d, avatarUrl = a })
        (D.field "conversation_id" D.int)
        (D.field "from_user_id" D.int)
        (D.oneOf [ D.at [ "profile", "display_name" ] D.string, D.succeed "Unknown" ])
        (D.oneOf [ D.at [ "profile", "avatar_url" ] D.string, D.succeed "" ])


callOutgoingDecoder : Decoder { convId : Int, displayName : String, avatarUrl : String }
callOutgoingDecoder =
    D.map3 (\c d a -> { convId = c, displayName = d, avatarUrl = a })
        (D.field "conversation_id" D.int)
        (D.oneOf [ D.at [ "profile", "display_name" ] D.string, D.succeed "Unknown" ])
        (D.oneOf [ D.at [ "profile", "avatar_url" ] D.string, D.succeed "" ])


callAcceptedDecoder : Decoder { convId : Int, userId : Int, displayName : String, avatarUrl : String }
callAcceptedDecoder =
    D.map4 (\c u d a -> { convId = c, userId = u, displayName = d, avatarUrl = a })
        (D.field "conversation_id" D.int)
        (D.field "user_id" D.int)
        (D.oneOf [ D.at [ "profile", "display_name" ] D.string, D.succeed "Unknown" ])
        (D.oneOf [ D.at [ "profile", "avatar_url" ] D.string, D.succeed "" ])


callStateDecoder : Decoder ( Int, List CallUser )
callStateDecoder =
    D.map2 Tuple.pair
        (D.field "conversation_id" D.int)
        (D.field "users" (D.list decodeCallUser))


callPresenceDecoder : Decoder ( Int, Bool, List CallUser )
callPresenceDecoder =
    D.map3 (\cid active users -> ( cid, active, users ))
        (D.field "conversation_id" D.int)
        (D.field "active" D.bool)
        (D.field "users" (D.list decodeCallUser))


voiceStateDecoder : Decoder ( Int, List VoiceUser )
voiceStateDecoder =
    D.map2 Tuple.pair
        (D.field "channel_id" D.int)
        (D.field "users" (D.list voiceUserDecoder))


voiceUserDecoder : Decoder VoiceUser
voiceUserDecoder =
    D.map8 VoiceUser
        (D.field "user_id" D.int)
        (D.oneOf [ D.at [ "profile", "display_name" ] D.string, D.succeed "" ])
        (D.oneOf [ D.at [ "profile", "avatar_url" ] D.string, D.succeed "" ])
        (D.field "muted" D.bool |> defaultValue False)
        (D.field "deafened" D.bool |> defaultValue False)
        (D.field "screen" D.bool |> defaultValue False)
        (D.field "screen_audio" D.bool |> defaultValue False)
        (D.field "reconnecting" D.bool |> defaultValue False)


callPeerJoinedDecoder : Decoder CallUser
callPeerJoinedDecoder =
    decodeCallUser


audioDeviceDecoder : Decoder AudioDevice
audioDeviceDecoder =
    D.map2 AudioDevice
        (D.field "id" D.string)
        (D.field "label" D.string)


audioDevicesDecoder :
    Decoder
        { inputs : List AudioDevice
        , outputs : List AudioDevice
        , selectedInput : String
        , selectedOutput : String
        , outputSupported : Bool
        , processingMode : String
        , krispAvailable : Bool
        , micMonitoring : Bool
        }
audioDevicesDecoder =
    D.map8
        (\inputs outputs selectedInput selectedOutput outputSupported processingMode krispAvailable micMonitoring ->
            { inputs = inputs
            , outputs = outputs
            , selectedInput = selectedInput
            , selectedOutput = selectedOutput
            , outputSupported = outputSupported
            , processingMode = processingMode
            , krispAvailable = krispAvailable
            , micMonitoring = micMonitoring
            }
        )
        (D.field "inputs" (D.list audioDeviceDecoder))
        (D.field "outputs" (D.list audioDeviceDecoder))
        (D.field "selected_input" D.string |> defaultValue "")
        (D.field "selected_output" D.string |> defaultValue "")
        (D.field "output_selection_supported" D.bool |> defaultValue False)
        (D.field "processing_mode" D.string |> defaultValue "noise")
        (D.field "krisp_available" D.bool |> defaultValue False)
        (D.field "mic_monitoring" D.bool |> defaultValue False)



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        clockInterval =
            if model.pageVisible then
                30000

            else
                120000

        syncInterval =
            if not model.pageVisible then
                300000

            else if model.wsConnected then
                300000

            else
                5000
    in
    Sub.batch
        [ onHashChange SetRoute
        , apiReceive decodeApi
        , wsReceive WsEvent
        , bridgeReceive decodeBridge
        , fileInput decodeFileInput
        , Browser.Events.onVisibilityChange (\visibility -> PageVisibility (visibility == Browser.Events.Visible))
        , Time.every clockInterval Tick
        , Time.every syncInterval (\_ -> SilentSync True)
        ]
