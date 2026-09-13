module Main exposing (main)

import Browser
import Browser.Events
import Browser.Navigation as Nav
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as D exposing (Decoder)
import Json.Encode as E
import Dict exposing (Dict)
import Set exposing (Set)
import Task
import Process
import Time
import Url exposing (Url)
import Ports exposing (..)
import Types exposing (..)


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
decodeBridge val = case D.decodeValue bridgeDecoder val of
    Ok msg -> msg
    Err _ -> NoOp

decodeFileInput : E.Value -> Msg
decodeFileInput val =
    case D.decodeValue (D.map2 FileUpload (D.field "id" D.string) (D.field "data" (D.nullable D.string))) val of
        Ok msg -> msg
        Err _ -> NoOp

bridgeDecoder : Decoder Msg
bridgeDecoder = D.field "tag" D.string |> D.andThen (\tag ->
    case tag of
        "toast" -> D.map Toast (D.field "data" D.string)
        "ws_event" -> D.map WsEvent (D.field "data" D.value)
        "sync_data" -> D.map handleSyncData (D.field "data" D.value)
        "hash_change" -> D.map SetRoute (D.field "data" D.string)
        "file_read" -> D.map2 FileUpload (D.field "id" D.string) (D.field "data" (D.nullable D.string))
        "load_more_messages" -> D.succeed LoadMoreMessages
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
        "tick" -> D.succeed (Tick (Time.millisToPosix 0))
        "presence_state" -> D.field "data" D.value |> D.map PresenceState
        "presence_online" -> D.field "data" (D.map2 PresenceOnline (D.field "user_id" D.int) (D.field "status" D.string))
        "presence_offline" -> D.map PresenceOffline (D.field "data" D.int)
        "presence_status" -> D.field "data" (D.map2 PresenceStatus (D.field "user_id" D.int) (D.field "status" D.string))
        "status_change" -> D.map SetMyStatus (D.field "data" D.string)
        "rtc_join_failed" -> D.map RtcJoinFailed (D.field "data" D.string)
        "audio_devices" -> D.map AudioDevices (D.field "data" D.value)
        "mic_test_level" -> D.map MicTestLevel (D.field "data" D.int)
        "mic_test_failed" -> D.map MicTestFailed (D.field "data" D.string)
        "ws_status" -> D.map WsStatus (D.field "data" D.bool)
        "rtc_resuming" ->
            D.map4 RtcResuming
                (D.field "room_kind" D.string)
                (D.field "room_id" D.int)
                (D.field "muted" D.bool)
                (D.field "deafened" D.bool)
        "sound_preference" -> D.map SetSoundPreference (D.field "data" D.bool)
        "chat_enter_sends" -> D.map SetChatEnterSends (D.field "data" D.bool)
        "turn_limit_reached" -> D.map SetTurnLimitReached (D.field "data" D.bool)
        "link_previews_enabled" -> D.map SetLinkPreviewsEnabled (D.field "data" D.bool)
        "animated_media_enabled" -> D.map SetAnimatedMediaEnabled (D.field "data" D.bool)
        "compact_messages" -> D.map SetCompactMessages (D.field "data" D.bool)
        "media_preload_enabled" -> D.map SetMediaPreloadEnabled (D.field "data" D.bool)
        "ui_preferences" -> D.map UiPreferences (D.field "data" D.value)
        _ -> D.succeed NoOp
    )

-- byte formatting for upload-limit copy, sourced from the server's actual
-- config (see pw_client_config:upload_max_bytes/0 via /api/client-config)
-- instead of a hardcoded number that can drift from what's really enforced.
formatBytesShort : Int -> String
formatBytesShort bytes =
    if bytes >= 1073741824 then
        String.fromInt (round (toFloat bytes / 1073741824)) ++ " GB"
    else
        String.fromInt (round (toFloat bytes / 1048576)) ++ " MB"


handleSyncData : E.Value -> Msg
handleSyncData val = case D.decodeValue decodeSyncData val of
    Ok d -> SilentSync True  -- will refetch
    Err _ -> NoOp


-- MAIN

type alias Flags =
    { appName : String
    , uploadMaxBytes : Int
    , registrationEnabled : Bool
    , instanceDescription : String
    , defaultTheme : String
    , version : String
    }

main : Program Flags Model Msg
main = Browser.application
    { init = init, update = update, view = view
    , subscriptions = subscriptions, onUrlChange = \_ -> NoOp
    , onUrlRequest = \_ -> NoOp
    }


-- INIT

init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url _ =
    let
        active = parseRoute (Maybe.withDefault "" url.fragment)
        appName = if String.isEmpty (String.trim flags.appName) then "Plainwire" else String.left 48 (String.trim flags.appName)
        defaultTheme = if List.member flags.defaultTheme [ "system", "light", "dark" ] then flags.defaultTheme else "system"
    in
    ( { appName = appName
      , uploadMaxBytes = if flags.uploadMaxBytes > 0 then flags.uploadMaxBytes else 262144000
      , turnLimitReached = False
      , registrationEnabled = flags.registrationEnabled
      , instanceDescription = String.left 120 (String.trim flags.instanceDescription)
      , clientVersion = String.left 32 (String.trim flags.version)
      , me = Nothing, csrf = "", serverTime = 0, timeZone = Time.utc, absoluteTimestamps = False
      , forums = [], threads = [], currentThread = Nothing, replies = []
      , servers = [], convs = [], conversationMembers = Dict.empty, friends = [], notifs = []
      , searchUsers = [], searchThreads = []
      , currentServer = Nothing, currentProfile = Nothing, invitePreview = Nothing
      , msg = [], nextBefore = Nothing, loadingOlderMessages = False, hasOlderMessages = True
      , active = active, serverCache = Dict.empty
      , drafts = Dict.empty, wsConnected = False, pageVisible = True, isLeader = False
      , tabId = "", subs = Set.empty
      , voice = { mode = Nothing, id = Nothing, stream = Nothing
                , peers = Dict.empty, failedPeers = Dict.empty, users = Dict.empty
                , muted = False, deafened = False, screenShare = False }
      , callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }
      , activeCalls = Dict.empty
      , callMode = Idle, soundEnabled = True, chatEnterSends = True, linkPreviewsEnabled = True, animatedMediaEnabled = True, compactMessages = False, mediaPreloadEnabled = True
      , uiDensity = "comfortable", uiFontScale = "default", uiAccent = "blue", uiCornerStyle = "default", reduceMotion = False, replyTo = Nothing
      , toast = Nothing, modal = Nothing, settingsTab = "profile"
      , inputText = "", sidebarOpen = False, serversSheetOpen = False, ctxMenu = Nothing
      , threadReply = "", searchQuery = ""
      , authMode = "login", authUsername = "", authBusy = False, authDisplayName = ""
      , authPassword = "", authPasswordConfirm = "", authPasswordVisible = False, serverName = "", serverDescription = "", booting = True, userStatuses = Dict.empty
      , failedMsgIds = Set.empty, currentProfileRelationship = "none", currentProfileBlockedByMe = False
      , pendingMessages = Dict.empty
      , profileDisplayName = "", profileBio = ""
      , profileAvatarUrl = "", profileBannerUrl = ""
      , profileAvatarPreviewUrl = "", profileBannerPreviewUrl = ""
      , profileAvatarUploading = False, profileBannerUploading = False
      , profileStatus = "online", profileTheme = defaultTheme
      , modalTitle = "", modalBody = "", modalUserIds = ""
      , modalBannerUrl = "", modalAccentColor = "#5865f2"
      , friendsTab = "online", friendQuery = "", friendSearchAttempted = False
        , pendingConversationId = Nothing
        , collapsedCategories = Set.empty
        , audioInputs = [], audioOutputs = []
        , selectedAudioInput = "", selectedAudioOutput = ""
        , outputSelectionSupported = False
        , voiceProcessingMode = "noise", krispAvailable = False
        , micTesting = False, micTestLevel = 0, micMonitoring = False
      }
    , Cmd.batch
        [ apiSend (encodeApiRequest (ApiGet "/me"))
        , requestNotifyPermission True
        , Task.perform GotTimeZone Time.here
        ]
    )


-- UPDATE

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp -> ( model, Cmd.none )

        SetRoute hash ->
            let route = String.dropLeft 1 hash
                active = parseRoute route
                clearedInvite =
                    case active of
                        InviteView _ -> Nothing
                        _ -> model.invitePreview
                clearedThread =
                    case active of
                        ThreadView _ -> Nothing
                        _ -> model.currentThread
                clearMessages = case ( model.active, active ) of
                    ( DmView a, DmView b ) -> a /= b
                    ( ChannelView a, ChannelView b ) -> a /= b
                    ( _, _ ) -> model.active /= active
                pendingId = case active of
                    DmView id -> if model.pendingConversationId == Just id then model.pendingConversationId else Nothing
                    _ -> Nothing
            in ( { model | active = active
                  , msg = if clearMessages then [] else model.msg
                  , sidebarOpen = False
                  , serversSheetOpen = False
                  , invitePreview = clearedInvite
                  , currentThread = clearedThread
                  , nextBefore = Nothing
                  , loadingOlderMessages = False
                  , hasOlderMessages = if clearMessages then True else model.hasOlderMessages
                  , pendingConversationId = pendingId
                  }
               , Cmd.batch
                    [ bridgeSend (E.object
                        [ ("tag", E.string "clear_subs")
                        , ("data", E.null)
                        ])
                    , routeCmd active
                    , routeSubCmd active
                    ]
               )

        AuthMode m -> ( { model | authMode = m, authPasswordConfirm = "", authPasswordVisible = False }, Cmd.none )
        AuthUsername s -> ( { model | authUsername = s }, Cmd.none )
        AuthDisplayName s -> ( { model | authDisplayName = s }, Cmd.none )
        AuthPassword s -> ( { model | authPassword = s }, Cmd.none )
        AuthPasswordConfirm s -> ( { model | authPasswordConfirm = s }, Cmd.none )
        ToggleAuthPasswordVisibility -> ( { model | authPasswordVisible = not model.authPasswordVisible }, Cmd.none )
        ServerName s -> ( { model | serverName = s }, Cmd.none )
        ServerDescription s -> ( { model | serverDescription = s }, Cmd.none )

        DoAuth ->
            let authError = authValidationError model
                path = if model.authMode == "login" then "/login" else "/register"
                body = E.object
                    [ ("username", E.string (String.trim model.authUsername))
                    , ("display_name", E.string (if String.isEmpty (String.trim model.authDisplayName) then String.trim model.authUsername else String.trim model.authDisplayName))
                    , ("password", E.string model.authPassword)
                    ] |> Just
            in case authError of
                Just err -> ( { model | toast = Just err }, Cmd.none )
                Nothing -> ( { model | authBusy = True, toast = Nothing }, apiSend (encodeApiRequest (ApiPost path body)) )

        ApiSuccess tag method val ->
            case ( tag, method ) of
                ( "/me", _ ) -> handleMe val model
                ( "/login", _ ) -> handleMe val model
                ( "/register", _ ) -> handleMe val model
                ( "/sync?since=0", _ ) -> handleSync val model
                ( "/forums", "GET" ) -> handleList (D.list decodeForum) (\items m -> { m | forums = items }) val model
                ( "/forums", _ ) -> handleCreateForum val model
                ( "/logout", _ ) -> ( model, bridgeSend (E.object [("tag", E.string "reload"), ("data", E.null)]) )
                ( "/profile", _ ) -> ( { model | toast = Just "Profile saved" }, apiSend (encodeApiRequest (ApiGet "/me")) )
                ( "/profile/theme", _ ) -> ( model, Cmd.none )
                ( "/notifications/seen", _ ) -> ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                ( "/notifications/clear", _ ) -> ( { model | notifs = [], toast = Just "Notifications cleared" }, Cmd.none )
                ( "/friends/request", _ ) -> ( { model | toast = Just "Friend request sent" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                ( "/friends/accept", _ ) -> ( { model | toast = Just "Friend added" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                ( "/friends/remove", _ ) -> ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                ( "/friends/block", _ ) -> ( { model | currentProfileRelationship = "blocked", currentProfileBlockedByMe = True, toast = Just "User blocked" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                ( "/friends/unblock", _ ) -> ( { model | currentProfileRelationship = "none", currentProfileBlockedByMe = False, toast = Just "User unblocked" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                ( "/conversations", _ ) -> handleCreateConversation val model
                ( "/threads", _ ) -> handleCreateThread val model
                ( _, _ ) ->
                    if String.startsWith "/threads?forum_id=" tag then
                        handleList (D.list decodeThread) (\items m -> { m | threads = items }) val model
                    else if String.startsWith "/thread/" tag && String.endsWith "/vote" tag then
                        handleThreadVote val model
                    else if String.startsWith "/forum/" tag && (String.endsWith "/join" tag || String.endsWith "/leave" tag) then
                        ( model, apiSend (encodeApiRequest (ApiGet "/forums")) )
                    else if String.startsWith "/thread/" tag && String.endsWith "/replies" tag then
                        handleReplyCreated val model
                    else if String.startsWith "/server/" tag && method == "POST" && String.contains "/categor" tag then
                        ( { model | toast = Just (if String.endsWith "/delete" tag then "Category deleted" else if String.contains "/category/" tag then "Category saved" else "Category created") }
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
                    else if String.startsWith "/channels/" tag && String.endsWith "/messages" tag then
                        handleMessageSent val model
                    else if String.startsWith "/conversation/" tag && String.endsWith "/messages" tag then
                        handleMessageSent val model
                    else if String.startsWith "/conversation/" tag && String.endsWith "/read" tag then
                        ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                    else if String.startsWith "/conversation/" tag && String.endsWith "/leave" tag then
                        ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                    else if String.startsWith "/conversation/" tag && String.endsWith "/members" tag then
                        ( { model | toast = Just "People added" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                    else if String.startsWith "/conversation/" tag && method == "GET" then
                        handleConversationDetail val model
                    else if String.startsWith "/conversation/" tag then
                        ( { model | toast = Just "Conversation updated" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                    else if String.startsWith "/users?q=" tag then
                        handleList (D.list decodeUser) (\items m -> { m | searchUsers = items }) val model
                    else if String.startsWith "/threads?q=" tag then
                        handleList (D.list decodeThread) (\items m -> { m | searchThreads = items }) val model
                    else if String.startsWith "/server/" tag && String.endsWith "/channels" tag then
                        ( { model | toast = Just "Channel created" }, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), routeCmd model.active ] )
                    else if String.startsWith "/server/" tag && String.endsWith "/invites" tag then
                        handleInviteCreated val model
                    else if String.startsWith "/server/" tag then
                        handleServerData val model
                    else if String.startsWith "/profile/" tag then
                        handleProfile val model
                    else if String.startsWith "/invites/" tag && String.endsWith "/join" tag then
                        handleInviteJoin val model
                    else if String.startsWith "/invites/" tag then
                        handleInvitePreview val model
                    else if tag == "/servers" then
                        handleCreateServer val model
                    else
                        ( model, Cmd.none )

        ApiError tag method err ->
            if String.startsWith "/invites/" tag && not (String.endsWith "/join" tag) then
                ( { model | invitePreview = Nothing, toast = Just (fmtErr err), modal = Just "join_invite", modalUserIds = "" }, setHash "#" )
            else if String.startsWith "/users?q=" tag then
                ( { model | friendSearchAttempted = False, toast = Just "Search is temporarily unavailable. Please try again." }, Cmd.none )
            else if err == "not_authenticated" && model.me == Nothing then
                ( { model | booting = False }, Cmd.none )
            else
                let pendingPairs = Dict.toList model.pendingMessages
                    failedPairs = List.filter (\(_, path) -> path == tag) pendingPairs
                    model2 = case failedPairs of
                        (msgId, _) :: _ ->
                            { model | failedMsgIds = Set.insert msgId model.failedMsgIds, pendingMessages = Dict.remove msgId model.pendingMessages }
                        [] -> model
                in ( { model2 | booting = False, authBusy = False, toast = Just (fmtErr err) }, Cmd.none )

        WsEvent val -> handleWsEvent val model

        Go hash -> ( model, setHash hash )

        ToggleSidebar -> ( { model | sidebarOpen = not model.sidebarOpen }, Cmd.none )
        CloseSidebar -> ( { model | sidebarOpen = False }, Cmd.none )
        ToggleServersSheet -> ( { model | serversSheetOpen = not model.serversSheetOpen }, Cmd.none )
        CloseServersSheet -> ( { model | serversSheetOpen = False }, Cmd.none )

        Toast s -> ( { model | toast = Just s }, Process.sleep 4000 |> Task.perform (\_ -> DismissToast) )
        DismissToast -> ( { model | toast = Nothing }, Cmd.none )
        GotTimeZone zone -> ( { model | timeZone = zone }, Cmd.none )
        ToggleTimestampMode -> ( { model | absoluteTimestamps = not model.absoluteTimestamps }, Cmd.none )
        CloseModal -> ( { model | modal = Nothing }, Cmd.none )

        InputText s -> ( { model | inputText = s }, Cmd.none )
        SendMessage -> sendMessage model

        SetReplyTo m -> ( { model | replyTo = Just
            { id = m.id, userId = m.userId, displayName = m.displayName
            , body = m.body } }, Cmd.none )
        CancelReply -> ( { model | replyTo = Nothing }, Cmd.none )

        VoteThread threadId value ->
            ( model
            , apiSend (encodeApiRequest (ApiPost ("/thread/" ++ String.fromInt threadId ++ "/vote") (Just (E.object [("value", E.int value)]))))
            )

        DeleteMessage mid ->
            ( { model | ctxMenu = Nothing }, apiSend (encodeApiRequest (ApiPost ("/delete_message/" ++ String.fromInt mid) (Just (E.object [])))) )

        LeaveConversation cid ->
            ( { model | ctxMenu = Nothing }, Cmd.batch [ apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/leave") (Just (E.object [])))), setHash "#dms" ] )

        CloseConversation cid ->
            ( { model | ctxMenu = Nothing }, Cmd.batch [ apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/close") (Just (E.object [])))), setHash "#dms" ] )

        RetryMessage msgId ->
            case findMessage msgId model.msg of
                Just m ->
                    let path = case m.scope of
                            "direct" -> "/conversation/" ++ String.fromInt m.scopeId ++ "/messages"
                            "channel" -> "/channels/" ++ String.fromInt m.scopeId ++ "/messages"
                            _ -> ""
                        payload = encodeMessage { body = m.body, replyToId = m.replyToId }
                    in
                    if String.isEmpty path then ( model, Cmd.none )
                    else
                        ( { model | failedMsgIds = Set.remove msgId model.failedMsgIds, pendingMessages = Dict.insert msgId path model.pendingMessages }
                        , apiSend (encodeApiRequest (ApiPost path (Just payload)))
                        )
                Nothing -> ( model, Cmd.none )

        DismissFailedMessage msgId ->
            ( { model | failedMsgIds = Set.remove msgId model.failedMsgIds, msg = List.filter (\m -> m.id /= msgId) model.msg }, Cmd.none )

        MarkConvRead cid -> ( model, apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/read") (Just (E.object [])))) )
        OpenMessageCtx m x y -> ( { model | ctxMenu = Just (messageContext model.me m x y) }, Cmd.none )
        OpenConvCtx c x y -> ( { model | ctxMenu = Just (conversationContext c x y) }, Cmd.none )
        OpenUserCtx user x y -> ( { model | ctxMenu = Just (userContext model user x y) }, Cmd.none )
        CopyText s -> ( { model | ctxMenu = Nothing }, copyText s )

        SilentSync _ ->
            ( model
            , if model.me == Nothing then Cmd.none else apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
            )

        Tick now ->
            ( { model | serverTime = Time.posixToMillis now }, Cmd.none )

        WsStatus connected ->
            ( { model | wsConnected = connected }
            , if connected && not model.wsConnected && model.me /= Nothing then
                apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
              else
                Cmd.none
            )

        PageVisibility visible ->
            ( { model | pageVisible = visible }
            , if visible && model.me /= Nothing then
                apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
              else
                Cmd.none
            )

        RtcResuming roomKind roomId muted deafened ->
            let
                voiceBase = updateVoiceMode roomKind roomId model.voice
                resumedVoice = { voiceBase | muted = muted, deafened = deafened }
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
            let enabled = not model.soundEnabled
            in ( { model | soundEnabled = enabled }
               , Cmd.batch
                    [ bridgeSend (E.object [("tag", E.string "set_sound_preference"), ("data", E.bool enabled)])
                    , if enabled then playNotification True else Cmd.none
                    ]
               )

        SetSoundPreference enabled ->
            ( { model | soundEnabled = enabled }, Cmd.none )

        SetChatEnterSends enabled ->
            ( { model | chatEnterSends = enabled }
            , bridgeSend (E.object [("tag", E.string "chat_enter_mode"), ("data", E.string (if enabled then "send" else "newline"))])
            )

        SetTurnLimitReached reached ->
            ( { model | turnLimitReached = reached }, Cmd.none )

        SetLinkPreviewsEnabled enabled ->
            ( { model | linkPreviewsEnabled = enabled }
            , bridgeSend (E.object [("tag", E.string "chat_set_link_previews"), ("data", E.bool enabled)])
            )

        SetAnimatedMediaEnabled enabled ->
            ( { model | animatedMediaEnabled = enabled }
            , bridgeSend (E.object [("tag", E.string "chat_set_animated_media"), ("data", E.bool enabled)])
            )

        SetCompactMessages enabled ->
            ( { model | compactMessages = enabled }
            , bridgeSend (E.object [("tag", E.string "chat_set_compact_messages"), ("data", E.bool enabled)])
            )

        SetMediaPreloadEnabled enabled ->
            ( { model | mediaPreloadEnabled = enabled }
            , bridgeSend (E.object [("tag", E.string "privacy_set_media_preload"), ("data", E.bool enabled)])
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

        Logout -> ( model, apiSend (encodeApiRequest (ApiPost "/logout" (Just (E.object [])))) )

        SetSettingsTab t ->
            ( { model
                | settingsTab = t
                , micTesting = if t == "voice" then model.micTesting else False
                , micTestLevel = if t == "voice" then model.micTestLevel else 0
                , micMonitoring = if t == "voice" then model.micMonitoring else False
              }
            , if t == "voice" then
                bridgeSend (E.object [("tag", E.string "list_audio_devices"), ("data", E.null)])
              else if model.micTesting then
                bridgeSend (E.object [("tag", E.string "stop_mic_test"), ("data", E.null)])
              else
                Cmd.none
            )

        SetFriendsTab tab ->
            ( { model | friendsTab = tab, friendQuery = if tab == "add" then model.friendQuery else "", searchUsers = if tab == "add" then model.searchUsers else [] }, Cmd.none )

        FriendQuery query -> ( { model | friendQuery = query, friendSearchAttempted = False }, Cmd.none )

        FindFriends ->
            let query = String.trim model.friendQuery
            in if String.length query < 2 then
                ( { model | toast = Just "Enter at least 2 characters." }, Cmd.none )
               else
                ( { model | searchUsers = [], friendSearchAttempted = True }, apiSend (encodeApiRequest (ApiGet ("/users?q=" ++ Url.percentEncode query))) )

        ProfileDisplayName s -> ( { model | profileDisplayName = s }, Cmd.none )
        ProfileBio s -> ( { model | profileBio = s }, Cmd.none )
        ProfileAvatarUrl s -> ( { model | profileAvatarUrl = s, profileAvatarPreviewUrl = s }, Cmd.none )
        ProfileBannerUrl s -> ( { model | profileBannerUrl = s, profileBannerPreviewUrl = s }, Cmd.none )
        ProfileStatus s ->
            let status = statusPreference s
            in ( { model | profileStatus = status }
               , bridgeSend (E.object [("tag", E.string "presence_update"), ("data", E.string status)])
               )
        ProfileTheme s ->
            ( { model | profileTheme = s }
            , Cmd.batch
                [ bridgeSend (E.object [("tag", E.string "set_theme"), ("data", E.string s)])
                , apiSend (encodeApiRequest (ApiPost "/profile/theme" (Just (E.object [("theme", E.string s)]))))
                ]
            )

        SaveProfile ->
            ( model
            , Cmd.batch
                [ apiSend (encodeApiRequest (ApiPost "/profile" (Just (E.object
                    [ ("display_name", E.string model.profileDisplayName)
                    , ("bio", E.string model.profileBio)
                    , ("avatar_url", E.string model.profileAvatarUrl)
                    , ("banner_url", E.string model.profileBannerUrl)
                    , ("status", E.string model.profileStatus)
                    , ("theme", E.string model.profileTheme)
                    ]))))
                , bridgeSend (E.object [("tag", E.string "presence_update"), ("data", E.string model.profileStatus)])
                ]
            )

        SearchQuery q -> ( { model | searchQuery = q }, Cmd.none )

        DoSearch -> ( model, setHash ("#search/" ++ model.searchQuery) )

        ClearNotifs -> ( model, apiSend (encodeApiRequest (ApiPost "/notifications/clear" (Just (E.object [])))) )

        CreateServer name description ->
            ( model
            , apiSend (encodeApiRequest (ApiPost "/servers" (Just (E.object [("name", E.string name), ("description", E.string description)]))))
            )

        JoinInvite ->
            case model.invitePreview of
                Just invite ->
                    ( model, apiSend (encodeApiRequest (ApiPost ("/invites/" ++ invite.code ++ "/join") (Just (E.object [])))) )
                Nothing ->
                    ( { model | toast = Just "Open an invite link like /#invite/CODE to join." }, Cmd.none )

        AcceptCall conversationId ->
            let active = { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
            in
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Just active }, callMode = Connected, voice = updateVoiceMode "call" conversationId model.voice }
            , Cmd.batch
                [ bridgeSend (E.object [("tag", E.string "accept_call"), ("data", E.int conversationId)])
                , playRingtone False
                ]
            )

        DeclineCall conversationId ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle }
            , Cmd.batch
                [ bridgeSend (E.object [("tag", E.string "decline_call"), ("data", E.int conversationId)])
                , playRingtone False
                , playOutgoingRingtone False
                ]
            )

        EndCall ->
            let
                myId = Maybe.map .id model.me
                markLeft active =
                    let remaining = List.filter (\u -> Just u.userId /= myId) active.users
                    in { active | users = remaining }
                clearedActive = case model.callUI.active of
                    Just a ->
                        let remaining = List.filter (\u -> Just u.userId /= myId) a.users
                        in if List.isEmpty remaining then Nothing else Just { a | users = remaining }
                    Nothing -> Nothing
            in
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = clearedActive }, callMode = Idle, voice = clearVoice model.voice }
            , bridgeSend (E.object [("tag", E.string "end_call"), ("data", E.null)])
            )

        ToggleCallOverlay ->
            let toggle a = { a | expanded = not a.expanded }
            in ( { model | callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = Maybe.map toggle model.callUI.active } }, Cmd.none )

        SetCallPeerConnected roomKind roomId userId connected ->
            ( setRtcPeerConnected roomKind roomId userId connected model, Cmd.none )

        SetCallPeerFailed roomKind roomId userId failed ->
            ( setRtcPeerFailed roomKind roomId userId failed model, Cmd.none )

        RetryCallPeer userId ->
            case ( model.voice.mode, model.voice.id ) of
                ( Just roomKind, Just roomId ) ->
                    ( model
                        |> setRtcPeerConnected roomKind roomId userId False
                        |> setRtcPeerFailed roomKind roomId userId False
                    , bridgeSend (E.object [("tag", E.string "retry_rtc_peer"), ("data", E.int userId)])
                    )

                _ ->
                    ( model, Cmd.none )

        StartCall conversationId ->
            let active = { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
            in
            ( { model | callUI = { incoming = Nothing, outgoing = model.callUI.outgoing, active = Just active }, callMode = Ringing, voice = updateVoiceMode "call" conversationId model.voice }
            , bridgeSend (E.object [("tag", E.string "start_call"), ("data", E.int conversationId)])
            )

        JoinCall conversationId ->
            let active = { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
            in
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Just active }, callMode = Connected, voice = updateVoiceMode "call" conversationId model.voice }
            , bridgeSend (E.object [("tag", E.string "accept_call"), ("data", E.int conversationId)])
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
            ( { model | modal = Just "new_dm", modalTitle = "", modalUserIds = "" }, Cmd.none )

        SearchUsersModal ->
            ( { model | modal = Just "search", searchQuery = "" }, Cmd.none )

        ModalTitle s -> ( { model | modalTitle = s }, Cmd.none )
        ModalBody s -> ( { model | modalBody = s }, Cmd.none )
        ModalUserIds s -> ( { model | modalUserIds = s }, Cmd.none )
        ModalBannerUrl s -> ( { model | modalBannerUrl = s }, Cmd.none )
        ModalAccentColor s -> ( { model | modalAccentColor = s }, Cmd.none )
        SetModalChoice field value ->
            case field of
                "body" -> ( { model | modalBody = value }, Cmd.none )
                "user_ids" -> ( { model | modalUserIds = value }, Cmd.none )
                "accent" -> ( { model | modalAccentColor = value }, Cmd.none )
                _ -> ( model, Cmd.none )
        SubmitModal -> submitModal model

        InviteModal serverId ->
            if serverId == 0 then
                ( { model | modal = Just "join_invite", modalTitle = "", modalBody = "0", modalUserIds = "" }, Cmd.none )
            else
                ( { model | modal = Just ("invite:" ++ String.fromInt serverId), modalTitle = "", modalBody = "0", modalUserIds = "" }, Cmd.none )

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
                , modalAccentColor = server.accentColor
              }
            , Cmd.none
            )

        EditConversationModal conversation ->
            ( { model | modal = Just ("edit_conversation:" ++ String.fromInt conversation.id), modalTitle = conversation.name, modalBody = "" }, Cmd.none )

        AddPeopleModal conversationId ->
            ( { model | modal = Just ("add_people:" ++ String.fromInt conversationId), modalUserIds = "", modalTitle = "" }, Cmd.none )

        ShowUserPopup userId ->
            ( model, setHash ("#profile/" ++ String.fromInt userId) )

        BridgeEvent tag data ->
            let cmd = bridgeSend (E.object [("tag", E.string tag), ("data", data)])
            in case tag of
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
                        Err _ -> ( model, cmd )
                "start_call" ->
                    case D.decodeValue D.int data of
                        Ok conversationId ->
                            let active = { conversationId = conversationId, users = [], startTime = model.serverTime, expanded = False }
                            in ( { model | callUI = { incoming = Nothing, outgoing = model.callUI.outgoing, active = Just active }, callMode = Ringing, voice = updateVoiceMode "call" conversationId model.voice }, cmd )
                        Err _ ->
                            ( model, cmd )
                "cancel_call" ->
                    ( { model | callUI = { incoming = model.callUI.incoming, outgoing = Nothing, active = Nothing }, callMode = Idle, voice = clearVoice model.voice }, cmd )
                "leave_voice" ->
                    ( { model | voice = clearVoice model.voice, callMode = Idle }, cmd )
                "toggle_mute" ->
                    if model.voice.deafened then
                        ( model, bridgeSend (E.object [("tag", E.string "toast"), ("data", E.string "Undeafen before unmuting.")]) )
                    else
                        ( { model | voice = toggleMute model.voice }, bridgeSend (E.object [("tag", E.string "voice_mute"), ("data", E.bool (not model.voice.muted))]) )
                "toggle_deafen" ->
                    let nextDeafened = not model.voice.deafened
                    in ( { model | voice = toggleDeafen model.voice }
                       , bridgeSend (E.object [("tag", E.string "voice_deafen"), ("data", E.bool nextDeafened)])
                       )
                "toggle_speaker" ->
                    ( model, cmd )
                "start_screen_share" ->
                    ( model, cmd )
                "stop_screen_share" ->
                    ( model, cmd )
                "screen_share_started" ->
                    let voice0 = model.voice
                    in ( { model | voice = { voice0 | screenShare = True } }, Cmd.none )
                "screen_share_stopped" ->
                    let voice0 = model.voice
                    in ( { model | voice = { voice0 | screenShare = False } }, Cmd.none )
                _ ->
                    ( model, cmd )

        ReadFile id ->
            ( if id == "profileAvatarFile" then
                { model | profileAvatarUploading = True }
              else if id == "profileBannerFile" then
                { model | profileBannerUploading = True }
              else model
            , readFile id )

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
                    ( { model | toast = Just "Could not upload that file"
                              , profileAvatarUploading = if id == "profileAvatarFile" then False else model.profileAvatarUploading
                              , profileBannerUploading = if id == "profileBannerFile" then False else model.profileBannerUploading
                      }, Cmd.none )

        CloseCtx ->
            ( { model | ctxMenu = Nothing }, Cmd.none )

        CtxAction idx ->
            case model.ctxMenu |> Maybe.andThen (\menu -> listAt idx menu.items) of
                Just item -> update item.msg { model | ctxMenu = Nothing }
                Nothing -> ( { model | ctxMenu = Nothing }, Cmd.none )

        PresenceState val ->
            case D.decodeValue (D.dict D.string) val of
                Ok statuses ->
                    let merged =
                            case model.me of
                                Just user -> Dict.insert (String.fromInt user.id) model.profileStatus statuses
                                Nothing -> statuses
                    in ( { model | userStatuses = merged }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        PresenceOnline uid status ->
            ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )
        PresenceOffline uid ->
            let isSelf = Maybe.map (\user -> user.id == uid) model.me |> Maybe.withDefault False
                statuses =
                    if isSelf && model.wsConnected then
                        Dict.insert (String.fromInt uid) model.profileStatus model.userStatuses
                    else
                        Dict.remove (String.fromInt uid) model.userStatuses
            in ( { model | userStatuses = statuses }, Cmd.none )
        PresenceStatus uid status ->
            ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )
        SetMyStatus status ->
            let statuses =
                    case model.me of
                        Just user -> Dict.insert (String.fromInt user.id) status model.userStatuses
                        Nothing -> model.userStatuses
            in ( { model | profileStatus = status, userStatuses = statuses }, Cmd.none )
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
                Err _ -> ( model, Cmd.none )
        SelectAudioInput deviceId ->
            ( { model | selectedAudioInput = deviceId, micTesting = False, micTestLevel = 0, micMonitoring = False }
            , bridgeSend (E.object [("tag", E.string "select_audio_input"), ("data", E.string deviceId)])
            )
        SelectAudioOutput deviceId ->
            ( { model | selectedAudioOutput = deviceId }
            , bridgeSend (E.object [("tag", E.string "select_audio_output"), ("data", E.string deviceId)])
            )
        SelectVoiceProcessing processingMode ->
            ( { model
                | voiceProcessingMode = processingMode
                , micTesting = False
                , micTestLevel = 0
                , micMonitoring = False
              }
            , bridgeSend (E.object [("tag", E.string "select_voice_processing"), ("data", E.string processingMode)])
            )
        ToggleMicTest ->
            let testing = not model.micTesting
            in ( { model
                    | micTesting = testing
                    , micTestLevel = if testing then model.micTestLevel else 0
                    , micMonitoring = if testing then model.micMonitoring else False
                 }
               , bridgeSend (E.object
                    [("tag", E.string (if testing then "start_mic_test" else "stop_mic_test")), ("data", E.null)])
               )
        ToggleMicMonitor ->
            let monitoring = model.micTesting && not model.micMonitoring
            in ( { model | micMonitoring = monitoring }
               , bridgeSend (E.object [("tag", E.string "set_mic_monitor"), ("data", E.bool monitoring)])
               )
        MicTestLevel level -> ( { model | micTestLevel = level }, Cmd.none )
        MicTestFailed message -> ( { model | micTesting = False, micTestLevel = 0, micMonitoring = False, toast = Just message }, Cmd.none )

        StartScreenShare ->
            ( model, bridgeSend (E.object [("tag", E.string "start_screen_share"), ("data", E.null)]) )

        StopScreenShare ->
            let voice0 = model.voice
            in ( { model | voice = { voice0 | screenShare = False } }, bridgeSend (E.object [("tag", E.string "stop_screen_share"), ("data", E.null)]) )

        ToggleCategory catId ->
            let newSet = if Set.member catId model.collapsedCategories then Set.remove catId model.collapsedCategories else Set.insert catId model.collapsedCategories
            in ( { model | collapsedCategories = newSet }, Cmd.none )

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
            ( model, apiSend (encodeApiRequest (ApiPost ("/channel/" ++ String.fromInt channelId ++ "/move") (Just (E.object [("category_id", maybeInt catId)]))) ))

        LoadMoreMessages ->
            if model.loadingOlderMessages || not model.hasOlderMessages then
                ( model, Cmd.none )
            else case ( model.active, model.msg ) of
                ( DmView id, firstMsg :: _ ) ->
                    ( { model | loadingOlderMessages = True }, Cmd.batch [ bridgeSend (E.object [("tag", E.string "preserve_message_scroll"), ("data", E.null)]), apiSend (encodeApiRequest (ApiGet ("/messages?scope=direct&scope_id=" ++ String.fromInt id ++ "&before=" ++ String.fromInt firstMsg.id))) ] )
                ( ChannelView id, firstMsg :: _ ) ->
                    ( { model | loadingOlderMessages = True }, Cmd.batch [ bridgeSend (E.object [("tag", E.string "preserve_message_scroll"), ("data", E.null)]), apiSend (encodeApiRequest (ApiGet ("/messages?scope=channel&scope_id=" ++ String.fromInt id ++ "&before=" ++ String.fromInt firstMsg.id))) ] )
                _ -> ( model, Cmd.none )


handleMe : E.Value -> Model -> ( Model, Cmd Msg )
handleMe val model =
    case D.decodeValue decodeUser (fromApiField "user" val) of
        Ok user ->
            let
                userValue = fromApiField "user" val
                avatarSource = D.decodeValue (D.field "avatar_source_url" D.string) userValue |> Result.withDefault user.avatarUrl
                bannerSource = D.decodeValue (D.field "banner_source_url" D.string) userValue |> Result.withDefault user.bannerUrl
                presence = statusPreference (statusToString user.status)
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
                [ bridgeSend (E.object [("tag", E.string "connect_ws"), ("data", E.null)])
                , bridgeSend (E.object [("tag", E.string "presence_update"), ("data", E.string presence)])
                , bridgeSend (E.object [("tag", E.string "set_theme"), ("data", E.string user.theme)])
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
                nextModel =
                    { model
                        | notifs = data.notifications
                        , convs = sortConvs (mergeConversationDetails model.convs data.conversations)
                        , servers = data.servers
                        , friends = data.friends
                        , serverTime = data.now
                    }
                redirectIfGone =
                    case model.active of
                        DmView id ->
                            if List.any (\c -> c.id == id) data.conversations then
                                -- conversation found, clear any pending flag
                                ( { nextModel | pendingConversationId = Nothing }, Cmd.none )
                            else if model.pendingConversationId == Just id then
                                -- stale sync, wait for the next one
                                ( nextModel, Cmd.none )
                            else
                                ( { nextModel | msg = [] }, setHash "#dms" )
                        _ -> ( nextModel, Cmd.none )
            in redirectIfGone
        Err _ -> ( model, Cmd.none )


mergeConversationDetails : List Conversation -> List Conversation -> List Conversation
mergeConversationDetails previous summaries =
    let preserveMembers summary =
            case List.filter (\old -> old.id == summary.id && not (List.isEmpty old.members)) previous |> List.head of
                Just old -> { summary | members = old.members, memberCount = Basics.max summary.memberCount (List.length old.members) }
                Nothing -> summary
    in List.map preserveMembers summaries


handleList : Decoder (List a) -> (List a -> Model -> Model) -> E.Value -> Model -> ( Model, Cmd Msg )
handleList decoder apply val model =
    case D.decodeValue decoder val of
        Ok items -> ( apply items model, Cmd.none )
        Err _ -> ( model, Cmd.none )


handleMessages : String -> E.Value -> Model -> ( Model, Cmd Msg )
handleMessages tag val model =
    case D.decodeValue (D.list decodeMessage) val of
        Ok items ->
            let cmd = case model.active of
                    DmView id ->
                        if String.isEmpty model.csrf then Cmd.none
                        else apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt id ++ "/read") (Just (E.object []))))
                    _ -> Cmd.none
                incoming = List.filter (\m -> m.deletedAt == Nothing) (List.reverse items)
                applies = List.all (messageApplies model.active) incoming
                incomingIds = Set.fromList (List.map .id incoming)
                preserved = List.filter (\m -> messageApplies model.active m && not (Set.member m.id incomingIds)) model.msg
                merged = List.sortBy .createdAt (incoming ++ preserved)
                olderPage = String.contains "&before=" tag
                hasOlder = if List.length items < 80 then False else model.hasOlderMessages
            in
            if applies then
                ( { model | msg = merged, loadingOlderMessages = False, hasOlderMessages = hasOlder }
                , if olderPage then
                    Cmd.batch [ cmd, bridgeSend (E.object [("tag", E.string "restore_message_scroll"), ("data", E.null)]) ]
                  else
                    Cmd.batch [ cmd, bridgeSend (E.object [("tag", E.string "scroll_messages_to_bottom"), ("data", E.null)]) ]
                )
            else
                ( { model | loadingOlderMessages = False }, Cmd.none )
        Err err ->
            ( { model | toast = Just ("Could not load messages: " ++ D.errorToString err), loadingOlderMessages = False }, Cmd.none )


handleThread : E.Value -> Model -> ( Model, Cmd Msg )
handleThread val model =
    case D.decodeValue threadDetailDecoder val of
        Ok detail -> ( { model | currentThread = Just detail.thread, replies = detail.replies }, Cmd.none )
        Err _ -> ( model, Cmd.none )


handleConversationDetail : E.Value -> Model -> ( Model, Cmd Msg )
handleConversationDetail val model =
    case ( D.decodeValue (D.at [ "conversation", "id" ] D.int) val, D.decodeValue (D.field "members" (D.list decodeMemberUser)) val ) of
        ( Ok conversationId, Ok members ) ->
            let updateConversation conversation =
                    if conversation.id == conversationId then
                        { conversation | members = members, memberCount = List.length members }
                    else
                        conversation
            in ( { model
                    | convs = List.map updateConversation model.convs
                    , conversationMembers = Dict.insert conversationId members model.conversationMembers
                 }
               , Cmd.none
               )
        _ ->
            ( { model | toast = Just "Could not load group members" }, Cmd.none )


handleMessageSent : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageSent val model =
    case D.decodeValue decodeMessage val of
        Ok message ->
            let newMsgs = List.filter (\m -> m.id > 0 && m.id /= message.id) model.msg ++ [ message ]
                negIds = List.map .id (List.filter (\m -> m.id < 0) model.msg)
                cleanedPending = List.foldl (\id acc -> Dict.remove id acc) model.pendingMessages negIds
                updateConversation conversation =
                    if message.scope == "direct" && conversation.id == message.scopeId then
                        { conversation
                            | lastBody = Just message.body
                            , lastMessageId = Just message.id
                            , updatedAt = message.createdAt
                            , unread = 0
                        }
                    else
                        conversation
            in
            ( { model
                | msg = newMsgs
                , convs = List.map updateConversation model.convs
                , inputText = ""
                , replyTo = Nothing
                , pendingMessages = cleanedPending
              }
            , Cmd.none
            )
        Err err ->
            ( { model | inputText = "", replyTo = Nothing, toast = Just ("Message sent, but could not display it yet: " ++ D.errorToString err) }, routeCmd model.active )


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
        Ok id -> ( model, setHash ("#thread/" ++ String.fromInt id) )
        Err _ -> ( model, apiSend (encodeApiRequest (ApiGet "/forums")) )


handleCreateForum : E.Value -> Model -> ( Model, Cmd Msg )
handleCreateForum val model =
    case D.decodeValue (D.field "id" D.int) val of
        Ok id ->
            ( { model | modal = Nothing, modalTitle = "", modalBody = "", modalUserIds = "" }
            , Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/forums")), setHash ("#forum/" ++ String.fromInt id) ]
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
                            , apiSend (encodeApiRequest (ApiPost "/threads" (Just (E.object
                                [ ("forum_id", E.int forumId)
                                , ("title", E.string model.modalTitle)
                                , ("body", E.string model.modalBody)
                                ]))))
                            )
                    Nothing ->
                        ( { model | toast = Just "Choose a category ID" }, Cmd.none )
            else if kind == "new_forum" then
                if String.length (String.trim model.modalTitle) < 2 then
                    ( { model | toast = Just "Add a community name" }, Cmd.none )
                else
                    ( { model | modal = Nothing }
                    , apiSend (encodeApiRequest (ApiPost "/forums" (Just (E.object
                        [ ("name", E.string model.modalTitle)
                        , ("slug", E.string model.modalUserIds)
                        , ("description", E.string model.modalBody)
                        ]))))
                    )
            else if kind == "new_dm" then
                let usernames = csvUsernames model.modalUserIds in
                if List.isEmpty usernames then
                    ( { model | toast = Just "Enter at least one username" }, Cmd.none )
                else
                    ( { model | modal = Nothing }
                    , apiSend (encodeApiRequest (ApiPost "/conversations" (Just (E.object
                        [ ("usernames", E.list E.string usernames)
                        , ("name", E.string model.modalTitle)
                        ]))))
                    )
            else if kind == "search" then
                ( { model | modal = Nothing }, setHash ("#search/" ++ model.searchQuery) )
            else if String.startsWith "channel:" kind then
                case String.toInt (String.dropLeft 8 kind) of
                    Just serverId ->
                        if String.isEmpty (String.trim model.modalTitle) then
                            ( { model | toast = Just "Add a channel name" }, Cmd.none )
                        else
                            ( { model | modal = Nothing }
                            , apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/channels") (Just (E.object
                                [ ("name", E.string model.modalTitle)
                                , ("kind", E.string model.modalBody)
                                , ("category_id", maybeInt (String.toInt (String.trim model.modalUserIds)))
                                ]))))
                            )
                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )
            else if String.startsWith "invite:" kind then
                case String.toInt (String.dropLeft 7 kind) of
                    Just serverId ->
                        ( { model | modal = Nothing }
                        , apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/invites") (Just (E.object
                            [ ("channel_id", maybeInt (String.toInt (String.trim model.modalUserIds)))
                            , ("max_uses", E.int (Maybe.withDefault 0 (String.toInt (String.trim model.modalBody))))
                            ]))))
                        )
                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )
            else if kind == "join_invite" then
                let code = String.trim model.modalUserIds
                in if String.isEmpty code then
                    ( { model | toast = Just "Enter an invite code" }, Cmd.none )
                else
                    ( { model | modal = Nothing }
                    , setHash ("#invite/" ++ code)
                    )

            else if String.startsWith "create_category:" kind then
                case String.toInt (String.dropLeft 16 kind) of
                    Just serverId ->
                        if String.isEmpty (String.trim model.modalTitle) then
                            ( { model | toast = Just "Add a category name" }, Cmd.none )
                        else
                            ( { model | modal = Nothing }
                            , apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/categories") (Just (E.object
                                [ ("name", E.string model.modalTitle) ]))))
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
                                    , apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/category/" ++ String.fromInt categoryId) (Just (E.object
                                        [ ("name", E.string model.modalTitle) ]))))
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
                            , apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt conversationId) (Just (E.object
                                [ ("name", E.string model.modalTitle) ]))))
                            )
                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if String.startsWith "add_people:" kind then
                case String.toInt (String.dropLeft 11 kind) of
                    Just conversationId ->
                        let usernames = csvUsernames model.modalUserIds in
                        if List.isEmpty usernames then
                            ( { model | toast = Just "Choose at least one username" }, Cmd.none )
                        else
                            ( { model | modal = Nothing }
                            , apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt conversationId ++ "/members") (Just (E.object
                                [ ("usernames", E.list E.string usernames) ]))))
                            )
                    Nothing ->
                        ( { model | modal = Nothing }, Cmd.none )

            else if String.startsWith "edit_server:" kind then
                case String.toInt (String.dropLeft 12 kind) of
                    Just serverId ->
                        if String.length (String.trim model.modalTitle) < 2 then
                            ( { model | toast = Just "Server name must be at least 2 characters" }, Cmd.none )
                        else
                            ( { model | modal = Nothing }
                            , apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId) (Just (E.object
                                [ ("name", E.string model.modalTitle)
                                , ("description", E.string model.modalBody)
                                , ("icon_url", E.string model.modalUserIds)
                                , ("banner_url", E.string model.modalBannerUrl)
                                , ("accent_color", E.string model.modalAccentColor)
                                ]))))
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
        Ok reply -> ( { model | replies = model.replies ++ [ reply ], inputText = "" }, Cmd.none )
        Err _ -> ( model, Cmd.none )


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
        Ok data -> ( { model | currentServer = Just data, serverCache = Dict.insert data.server.id data model.serverCache }, Cmd.none )
        Err _ -> ( { model | toast = Just "Server saved" }, routeCmd model.active )


handleInviteCreated : E.Value -> Model -> ( Model, Cmd Msg )
handleInviteCreated val model =
    case ( D.decodeValue (D.field "code" D.string) val, D.decodeValue (D.field "url" D.string) val ) of
        ( Ok code, Ok url ) ->
            ( { model | modal = Just ("invite_result:" ++ code ++ ":" ++ url) }
            , Cmd.none
            )
        _ ->
            ( { model | modal = Just ("invite_result:error:") }, Cmd.none )


serverDataDecoder : Decoder ServerData
serverDataDecoder =
    D.map4 (\server channels members categories -> { server = server, channels = channels, members = members, categories = categories })
        (D.field "server" decodeServer)
        (D.field "channels" (D.list decodeChannel))
        (D.field "members" (D.list decodeServerMember))
        (D.field "categories" (D.list decodeCategory) |> defaultValue [])


handleProfile : E.Value -> Model -> ( Model, Cmd Msg )
handleProfile val model =
    let userResult = D.decodeValue (D.field "user" decodeUser) val
        relResult = D.decodeValue (D.field "relationship" (D.field "status" D.string)) val
        blockedByMe = D.decodeValue (D.at [ "relationship", "blocked_by_me" ] D.bool) val |> Result.withDefault False
        rel = case relResult of
            Ok r -> r
            Err _ -> "none"
    in case userResult of
        Ok user -> ( { model | currentProfile = Just user, currentProfileRelationship = rel, currentProfileBlockedByMe = blockedByMe }, Cmd.none )
        Err _ -> ( model, Cmd.none )


handleInvitePreview : E.Value -> Model -> ( Model, Cmd Msg )
handleInvitePreview val model =
    case D.decodeValue invitePreviewDecoder val of
        Ok invite -> ( { model | invitePreview = Just invite }, Cmd.none )
        Err _ -> ( { model | invitePreview = Nothing, toast = Just "Could not load that invite.", modal = Just "join_invite", modalUserIds = "" }, setHash "#" )


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
        Ok id -> ( { model | serverName = "", serverDescription = "" }, setHash ("#server/" ++ String.fromInt id) )
        Err _ -> ( model, Cmd.none )


handleInviteJoin : E.Value -> Model -> ( Model, Cmd Msg )
handleInviteJoin val model =
    case D.decodeValue (D.field "server_id" D.int) val of
        Ok id -> ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), setHash ("#server/" ++ String.fromInt id) ] )
        Err _ -> ( model, Cmd.none )


routeCmd : ActiveRoute -> Cmd Msg
routeCmd active =
    case active of
        Forums -> apiSend (encodeApiRequest (ApiGet "/forums"))
        ForumView id -> apiSend (encodeApiRequest (ApiGet ("/threads?forum_id=" ++ String.fromInt id)))
        ThreadView id -> apiSend (encodeApiRequest (ApiGet ("/thread/" ++ String.fromInt id)))
        DmView id -> Cmd.batch
            [ apiSend (encodeApiRequest (ApiGet ("/messages?scope=direct&scope_id=" ++ String.fromInt id)))
            , apiSend (encodeApiRequest (ApiGet ("/conversation/" ++ String.fromInt id)))
            ]
        ChannelView id -> apiSend (encodeApiRequest (ApiGet ("/messages?scope=channel&scope_id=" ++ String.fromInt id)))
        ServerView id -> apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt id)))
        ProfileView id -> apiSend (encodeApiRequest (ApiGet ("/profile/" ++ String.fromInt id)))
        InviteView code -> if code /= "" then apiSend (encodeApiRequest (ApiGet ("/invites/" ++ code))) else Cmd.none
        SearchView q -> Cmd.batch
            [ apiSend (encodeApiRequest (ApiGet ("/users?q=" ++ q)))
            , apiSend (encodeApiRequest (ApiGet ("/threads?q=" ++ q)))
            ]
        _ -> Cmd.none


routeSubCmd : ActiveRoute -> Cmd Msg
routeSubCmd active =
    case active of
        ForumView id -> wsSend (E.object [("type", E.string "subscribe"), ("key", E.string ("forum:" ++ String.fromInt id))])
        ThreadView id -> wsSend (E.object [("type", E.string "subscribe"), ("key", E.string ("thread:" ++ String.fromInt id))])
        DmView id -> wsSend (E.object [("type", E.string "subscribe"), ("key", E.string ("direct:" ++ String.fromInt id))])
        ServerView id -> wsSend (E.object [("type", E.string "subscribe"), ("key", E.string ("server:" ++ String.fromInt id))])
        ChannelView id -> wsSend (E.object [("type", E.string "subscribe"), ("key", E.string ("channel:" ++ String.fromInt id))])
        _ -> Cmd.none


updateVoiceMode : String -> Int -> VoiceState -> VoiceState
updateVoiceMode mode id voice =
    if voice.mode == Just mode && voice.id == Just id then
        voice
    else
        { voice | mode = Just mode, id = Just id, stream = Nothing
        , peers = Dict.empty, failedPeers = Dict.empty, users = Dict.empty, screenShare = False }


clearVoice : VoiceState -> VoiceState
clearVoice voice =
    { voice | mode = Nothing, id = Nothing, stream = Nothing, screenShare = False
    , peers = Dict.empty, failedPeers = Dict.empty, users = Dict.empty }


setRtcPeerConnected : String -> Int -> Int -> Bool -> Model -> Model
setRtcPeerConnected roomKind roomId userId connected model =
    let
        roomIsCurrent = model.voice.mode == Just roomKind && model.voice.id == Just roomId
        updateUser user =
            if user.userId == userId then
                { user
                    | connected = connected
                    , connectionFailed = if connected then False else user.connectionFailed
                }
            else
                user
        updateActive active = { active | users = List.map updateUser active.users }
        voice0 = model.voice
        nextVoice =
            if roomIsCurrent then
                { voice0
                    | peers = Dict.insert userId connected voice0.peers
                    , failedPeers = if connected then Dict.insert userId False voice0.failedPeers else voice0.failedPeers
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
        roomIsCurrent = model.voice.mode == Just roomKind && model.voice.id == Just roomId
        updateUser user =
            if user.userId == userId then
                { user | connectionFailed = failed, connected = if failed then False else user.connected }
            else
                user
        updateActive active = { active | users = List.map updateUser active.users }
        voice0 = model.voice
        nextVoice =
            if roomIsCurrent then
                { voice0
                    | failedPeers =
                        if failed then
                            Dict.insert userId True voice0.failedPeers
                        else
                            Dict.insert userId False voice0.failedPeers
                    , peers = if failed then Dict.insert userId False voice0.peers else voice0.peers
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
        previous = List.filter (\old -> old.userId == user.userId) existingUsers |> List.head
        previousConnected = Maybe.map .connected previous |> Maybe.withDefault user.connected
        previousFailed = Maybe.map .connectionFailed previous |> Maybe.withDefault user.connectionFailed
        roomIsCurrent = model.voice.mode == Just roomKind && model.voice.id == Just roomId
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
    { voice | muted = not voice.muted }


toggleDeafen : VoiceState -> VoiceState
toggleDeafen voice =
    if voice.deafened then
        { voice | deafened = False }
    else
        { voice | deafened = True, muted = True }


sendMessage : Model -> ( Model, Cmd Msg )
sendMessage model =
    let body = String.trim model.inputText
        replyField = Maybe.map .id model.replyTo
        payload = encodeMessage { body = body, replyToId = replyField }
        scrollToBottom = bridgeSend (E.object [("tag", E.string "scroll_messages_to_bottom"), ("data", E.null)])
    in
    if String.isEmpty body then
        ( model, Cmd.none )
    else
        case model.active of
            DmView id ->
                let path = "/conversation/" ++ String.fromInt id ++ "/messages"
                    model2 = appendOptimisticMessage "direct" id body model
                    lastMsgId = case List.reverse model2.msg of
                        m :: _ -> m.id
                        [] -> -1
                in
                ( { model2 | pendingMessages = Dict.insert lastMsgId path model.pendingMessages, failedMsgIds = Set.remove lastMsgId model.failedMsgIds }
                , Cmd.batch [ apiSend (encodeApiRequest (ApiPost path (Just payload))), scrollToBottom ]
                )
            ChannelView id ->
                let path = "/channels/" ++ String.fromInt id ++ "/messages"
                    model2 = appendOptimisticMessage "channel" id body model
                    lastMsgId = case List.reverse model2.msg of
                        m :: _ -> m.id
                        [] -> -1
                in
                ( { model2 | pendingMessages = Dict.insert lastMsgId path model.pendingMessages, failedMsgIds = Set.remove lastMsgId model.failedMsgIds }
                , Cmd.batch [ apiSend (encodeApiRequest (ApiPost path (Just payload))), scrollToBottom ]
                )
            ThreadView id ->
                ( model, apiSend (encodeApiRequest (ApiPost ("/thread/" ++ String.fromInt id ++ "/replies") (Just (E.object [("body", E.string body)])))) )
            _ ->
                ( model, Cmd.none )

appendOptimisticMessage : String -> Int -> String -> Model -> Model
appendOptimisticMessage scope scopeId body model =
    case model.me of
        Just user ->
            let optimistic = Message
                    (-1 - List.length model.msg)
                    scope
                    scopeId
                    user.id
                    user.username
                    user.displayName
                    user.avatarUrl
                    body
                    (Maybe.map .id model.replyTo)
                    model.replyTo
                    (if model.serverTime > 0 then model.serverTime else 0)
                    Nothing
                    Nothing
            in { model | msg = model.msg ++ [ optimistic ], inputText = "", replyTo = Nothing }
        Nothing ->
            model


findMessage : Int -> List Message -> Maybe Message
findMessage msgId msgs =
    case msgs of
        [] -> Nothing
        m :: rest -> if m.id == msgId then Just m else findMessage msgId rest


handleWsEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleWsEvent val model =
    case D.decodeValue wsEventDecoder val of
        Ok ( "message_created", ev ) ->
            handleMessageCreated ev model
        Ok ( "message_deleted", ev ) ->
            handleMessageDeleted ev model
        Ok ( "direct_message", _ ) ->
            handleNotifiedMessage val model
        Ok ( "channel_message", _ ) ->
            handleNotifiedMessage val model
        Ok ( "notification", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "friend_request", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "friend_accept", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "conversation_created", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "conversation_members_added", ev ) ->
            handleConversationStructureEvent ev model
        Ok ( "conversation_members_changed", ev ) ->
            handleConversationStructureEvent ev model
        Ok ( "conversation_updated", ev ) ->
            handleConversationStructureEvent ev model
        Ok ( "server_updated", ev ) ->
            handleServerStructureEvent ev model
        Ok ( "channel_created", ev ) ->
            handleServerStructureEvent ev model
        Ok ( "member_joined", ev ) ->
            handleServerStructureEvent ev model
        Ok ( "thread_created", ev ) ->
            handleThreadListEvent ev model
        Ok ( "thread_deleted", ev ) ->
            handleThreadDeletedEvent ev model
        Ok ( "forum_deleted", ev ) ->
            handleForumDeletedEvent ev model
        Ok ( "thread_reply", ev ) ->
            handleThreadReplyEvent ev model
        Ok ( "call_incoming", ev ) ->
            handleCallIncoming ev model
        Ok ( "call_ringing", ev ) ->
            case D.decodeValue callOutgoingDecoder ev of
                Ok out ->
                    let
                        active =
                            case model.callUI.active of
                                Just current ->
                                    if current.conversationId == out.convId then current
                                    else { conversationId = out.convId, users = [], startTime = model.serverTime, expanded = False }
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
                            { userId = accepted.userId, displayName = accepted.displayName, avatarUrl = accepted.avatarUrl
                            , muted = False, deafened = False, connected = False
                            , connectionFailed = False, reconnecting = False
                            }
                        peer = mergeCallUserRtc "call" accepted.convId [] model rawPeer
                        addPeer users =
                            if List.any (\u -> u.userId == peer.userId) users then
                                users
                            else
                                users ++ [ peer ]
                        active =
                            case model.callUI.active of
                                Just a ->
                                    Just { a | conversationId = if a.conversationId == 0 then accepted.convId else a.conversationId, users = addPeer a.users }
                                Nothing ->
                                    Just { conversationId = accepted.convId, users = [ peer ], startTime = model.serverTime, expanded = False }
                    in
                    let
                        nextCalls =
                            case active of
                                Just call -> Dict.insert accepted.convId call model.activeCalls
                                Nothing -> model.activeCalls
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
        Ok ( "call_declined", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
        Ok ( "call_cancelled", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
        Ok ( "call_ended", ev ) ->
            case D.decodeValue (D.field "reason" D.string) ev of
                Ok "accepted" ->
                    ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = model.callUI.active } }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
                _ ->
                    let cid = case D.decodeValue (D.field "conversation_id" D.int) ev of
                            Ok id -> id
                            Err _ -> 0
                        joinedCall = isJoinedCall cid model
                    in if joinedCall then
                        ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = model.callUI.active } }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
                       else
                        ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }, callMode = Idle, voice = clearVoice model.voice }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
        Ok ( "call_state", ev ) ->
            case D.decodeValue callStateDecoder ev of
                Ok ( cid, users ) ->
                    if not (isJoinedCall cid model) then
                        ( model, Cmd.none )
                    else
                        let existing = Maybe.andThen (\a -> if a.conversationId == cid then Just a else Nothing) model.callUI.active
                            mappedUsers = Dict.get cid model.activeCalls |> Maybe.map .users |> Maybe.withDefault []
                            existingUsers = Maybe.withDefault [] (Maybe.map .users existing) ++ mappedUsers
                            safeUsers =
                                if List.isEmpty users && isJoinedCall cid model then
                                    Maybe.withDefault [] (Maybe.map .users existing)
                                else
                                    List.map (mergeCallUserRtc "call" cid existingUsers model) users
                            active = { conversationId = cid, users = safeUsers
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
                Err _ -> ( model, Cmd.none )
        Ok ( "call_presence", ev ) ->
            handleCallPresence ev model
        Ok ( "call_peer_joined", ev ) ->
            case ( D.decodeValue (D.field "conversation_id" D.int) ev, D.decodeValue callPeerJoinedDecoder ev ) of
                ( Ok cid, Ok peer ) ->
                    let
                        knownPeer = mergeCallUserRtc "call" cid [] model peer
                        addUser users =
                            if List.any (\u -> u.userId == knownPeer.userId) users then
                                users
                            else
                                users ++ [ knownPeer ]
                        updateActive a = { a | users = addUser a.users }
                    in if isJoinedCall cid model then
                        let
                            nextOverlay = Maybe.map updateActive model.callUI.active
                            nextCalls =
                                case nextOverlay of
                                    Just active -> Dict.insert cid active model.activeCalls
                                    Nothing -> Dict.update cid (Maybe.map updateActive) model.activeCalls
                        in
                        ( { model
                            | activeCalls = nextCalls
                            , callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = nextOverlay }
                          }
                        , Cmd.none
                        )
                       else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        Ok ( "call_peer_left", ev ) ->
            case ( D.decodeValue (D.field "conversation_id" D.int) ev, D.decodeValue (D.field "user_id" D.int) ev ) of
                ( Ok cid, Ok uid ) ->
                    let removeUser users = List.filter (\u -> u.userId /= uid) users
                        updateActive a = { a | users = removeUser a.users }
                    in if isJoinedCall cid model then
                        let
                            nextOverlay = Maybe.map updateActive model.callUI.active
                            nextCalls =
                                case nextOverlay of
                                    Just active -> Dict.insert cid active model.activeCalls
                                    Nothing -> Dict.update cid (Maybe.map updateActive) model.activeCalls
                            voice0 = model.voice
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
                       else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        Ok ( "call_signal", ev ) -> ( model, Cmd.none )
        Ok ( "call_superseded", ev ) ->
            clearSupersededCall ev model
        Ok ( "call_ejected", ev ) ->
            clearSupersededCall ev model
        Ok ( "voice_state", ev ) ->
            case D.decodeValue voiceStateDecoder ev of
                Ok ( channelId, users ) ->
                    let
                        userDict = Dict.fromList (List.map (\u -> ( u.userId, u )) users)
                        voice0 = model.voice
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
                    let voice0 = model.voice
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
        Ok ( "voice_user_joined", ev ) -> ( model, Cmd.none )
        Ok ( "voice_user_left", ev ) -> ( model, Cmd.none )
        Ok ( "voice_signal", ev ) -> ( model, Cmd.none )
        Ok ( "voice_superseded", _ ) ->
            ( { model | voice = clearVoice model.voice, callMode = Idle }, Cmd.none )
        Ok ( "voice_ejected", _ ) ->
            ( { model | voice = clearVoice model.voice, callMode = Idle }, Cmd.none )
        Ok ( "presence_state", ev ) ->
            case D.decodeValue (D.field "statuses" (D.dict D.string)) ev of
                Ok statuses -> ( { model | userStatuses = statuses }, Cmd.none )
                Err _ ->
                    case D.decodeValue (D.field "online" (D.list D.int)) ev of
                        Ok ids -> ( { model | userStatuses = Dict.fromList (List.map (\id -> ( String.fromInt id, "online" )) ids) }, Cmd.none )
                        Err _ -> ( model, Cmd.none )
        Ok ( "presence_online", ev ) ->
            case D.decodeValue (D.map2 (\uid s -> ( uid, s )) (D.field "user_id" D.int) (D.field "status" D.string |> D.maybe |> D.map (Maybe.withDefault "online"))) ev of
                Ok ( uid, status ) -> ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        Ok ( "presence_offline", ev ) ->
            case D.decodeValue (D.field "user_id" D.int) ev of
                Ok uid -> ( { model | userStatuses = Dict.remove (String.fromInt uid) model.userStatuses }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        Ok ( "error", ev ) ->
            ( model
            , bridgeSend (E.object
                [ ("tag", E.string "toast")
                , ("data", E.string "error")
                ])
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
        _ -> ( model, Cmd.none )


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
                        ( model, setHash ("#forum/" ++ String.fromInt forumId) )
                    else
                        ( model, Cmd.none )
                ForumView currentId ->
                    if currentId == forumId then ( model, routeCmd model.active ) else ( model, Cmd.none )
                _ ->
                    ( model, Cmd.none )
        _ ->
            ( model, Cmd.none )


handleForumDeletedEvent : E.Value -> Model -> ( Model, Cmd Msg )
handleForumDeletedEvent ev model =
    case ( D.decodeValue (D.field "forum_id" D.int) ev, model.active ) of
        ( Ok forumId, ForumView currentId ) ->
            if forumId == currentId then ( model, setHash "#forums" ) else ( model, Cmd.none )
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


clearSupersededCall : E.Value -> Model -> ( Model, Cmd Msg )
clearSupersededCall ev model =
    let
        conversationId = D.decodeValue (D.field "conversation_id" D.int) ev |> Result.withDefault 0
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
            let alreadyPresent = List.any (\existing -> existing.id == message.id) model.msg
                fromMe = Maybe.map .id model.me == Just message.userId
                notification = if fromMe then Cmd.none else playNotification model.soundEnabled
            in if alreadyPresent then
                ( model, Cmd.none )
            else if messageApplies model.active message then
                ( { model | msg = List.filter (\m -> m.id /= message.id) model.msg ++ [ message ] }
                , Cmd.batch
                    [ notification
                    , bridgeSend (E.object [("tag", E.string "scroll_messages_to_bottom"), ("data", E.null)])
                    ]
                )
            else
                ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), notification ] )
        Err _ -> ( model, Cmd.none )

handleNotifiedMessage : E.Value -> Model -> ( Model, Cmd Msg )
handleNotifiedMessage ev model =
    case D.decodeValue (D.field "message" decodeMessage) ev of
        Ok message ->
            let alreadyPresent = List.any (\existing -> existing.id == message.id) model.msg
            in if alreadyPresent then
                ( model, Cmd.none )
            else if messageApplies model.active message then
                ( { model | msg = List.filter (\m -> m.id /= message.id) model.msg ++ [ message ] }
                , Cmd.batch
                    [ playNotification model.soundEnabled
                    , bridgeSend (E.object [("tag", E.string "scroll_messages_to_bottom"), ("data", E.null)])
                    ]
                )
            else
                ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), playNotification model.soundEnabled ] )
        Err _ ->
            ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), playNotification model.soundEnabled ] )

handleCallPresence : E.Value -> Model -> ( Model, Cmd Msg )
handleCallPresence ev model =
    case D.decodeValue callPresenceDecoder ev of
        Ok ( cid, activeNow, users ) ->
            let existing =
                    case Dict.get cid model.activeCalls of
                        Just call -> Just call
                        Nothing -> Maybe.andThen (\call -> if call.conversationId == cid then Just call else Nothing) model.callUI.active
                overlayUsers =
                    Maybe.andThen
                        (\call -> if call.conversationId == cid then Just call.users else Nothing)
                        model.callUI.active
                        |> Maybe.withDefault []
                existingUsers = Maybe.withDefault [] (Maybe.map .users existing) ++ overlayUsers
                mergeConnected user =
                    mergeCallUserRtc "call" cid existingUsers model user
                nextCall =
                    { conversationId = cid
                    , users = List.map mergeConnected users
                    , startTime = Maybe.withDefault model.serverTime (Maybe.map .startTime existing)
                    , expanded = Maybe.withDefault False (Maybe.map .expanded existing)
                    }
                nextCalls = if activeNow then Dict.insert cid nextCall model.activeCalls else Dict.remove cid model.activeCalls
                nextOverlay =
                    if activeNow && isJoinedCall cid model then
                        Just nextCall
                    else
                        case model.callUI.active of
                            Just call -> if not activeNow && call.conversationId == cid && not (isJoinedCall cid model) then Nothing else Just call
                            Nothing -> Nothing
            in if activeNow then
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
        Err _ -> ( model, Cmd.none )

handleMessageDeleted : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageDeleted ev model =
    case D.decodeValue (D.field "message_id" D.int) ev of
        Ok messageId -> ( { model | msg = List.filter (\m -> m.id /= messageId) model.msg }, Cmd.none )
        Err _ -> ( model, Cmd.none )

messageApplies : ActiveRoute -> Message -> Bool
messageApplies active message =
    case active of
        DmView id -> message.scope == "direct" && message.scopeId == id
        ChannelView id -> message.scope == "channel" && message.scopeId == id
        _ -> False

handleCallIncoming : E.Value -> Model -> ( Model, Cmd Msg )
handleCallIncoming ev model =
    case D.decodeValue callIncomingDecoder ev of
        Ok { convId, userId, displayName, avatarUrl } ->
            ( { model | callUI =
                { incoming = Just { conversationId = convId, userId = userId
                                  , displayName = displayName, avatarUrl = avatarUrl }
                , outgoing = Nothing, active = model.callUI.active }
              , callMode = Ringing
              }
            , bridgeSend (E.object
                [ ("tag", E.string "play_ringtone")
                , ("data", E.null)
                ])
            )
        Err _ -> ( model, Cmd.none )

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

voiceStateDecoder : Decoder ( Int, List { userId : Int, muted : Bool, deafened : Bool, screen : Bool, reconnecting : Bool } )
voiceStateDecoder =
    D.map2 Tuple.pair
        (D.field "channel_id" D.int)
        (D.field "users" (D.list voiceUserDecoder))

voiceUserDecoder : Decoder { userId : Int, muted : Bool, deafened : Bool, screen : Bool, reconnecting : Bool }
voiceUserDecoder =
    D.map5 (\uid muted deafened screen reconnecting -> { userId = uid, muted = muted, deafened = deafened, screen = screen, reconnecting = reconnecting })
        (D.field "user_id" D.int)
        (D.field "muted" D.bool |> defaultValue False)
        (D.field "deafened" D.bool |> defaultValue False)
        (D.field "screen" D.bool |> defaultValue False)
        (D.field "reconnecting" D.bool |> defaultValue False)

callPeerJoinedDecoder : Decoder CallUser
callPeerJoinedDecoder =
    D.map8 CallUser
        (D.field "user_id" D.int)
        (D.oneOf [ D.at [ "profile", "display_name" ] D.string, D.succeed "Unknown" ])
        (D.oneOf [ D.at [ "profile", "avatar_url" ] D.string, D.succeed "" ])
        (D.succeed False)
        (D.succeed False)
        (D.succeed False)
        (D.succeed False)
        (D.succeed False)

audioDeviceDecoder : Decoder AudioDevice
audioDeviceDecoder =
    D.map2 AudioDevice
        (D.field "id" D.string)
        (D.field "label" D.string)

audioDevicesDecoder : Decoder
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
            { inputs = inputs, outputs = outputs, selectedInput = selectedInput
            , selectedOutput = selectedOutput, outputSupported = outputSupported
            , processingMode = processingMode, krispAvailable = krispAvailable
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


-- VIEW

view : Model -> Browser.Document Msg
view model =
    { title = titleText model
    , body =
        [ if model.booting then div [ class "boot" ] [ text ("Loading " ++ model.appName ++ "...") ]
          else case model.me of
            Nothing -> renderAuth model
            Just _ -> renderApp model
        , renderToast model
        , renderCallLayer model
        ]
    }

titleText : Model -> String
titleText model =
    let unread = List.length (List.filter (\n -> not n.seen) model.notifs)
    in if unread > 0 then "(" ++ String.fromInt unread ++ ") " ++ model.appName else model.appName


renderToast : Model -> Html Msg
renderToast model = case model.toast of
    Just msg ->
        div [ class "toast toast-visible" ]
            [ span [ class "toast-text" ] [ text msg ]
            , button [ class "toast-close", onClick DismissToast ] [ callIcon "close" ]
            ]
    Nothing -> text ""

renderContextMenu : Model -> Html Msg
renderContextMenu model =
    case model.ctxMenu of
        Just menu ->
            div [ class "ctx-backdrop", onClick CloseCtx ]
                [ div [ class "ctx-menu", style "left" (String.fromInt menu.x ++ "px"), style "top" (String.fromInt menu.y ++ "px") ]
                    (List.indexedMap ctxItemView menu.items)
                ]
        Nothing -> text ""

renderModal : Model -> Html Msg
renderModal model =
    case model.modal of
        Just kind ->
            div [ class "modal", onClick CloseModal ]
                [ div [ class "modal-card action-modal", stopClick ]
                    (modalContent kind model)
                ]
        Nothing -> text ""

modalContent : String -> Model -> List (Html Msg)
modalContent kind model =
    if String.startsWith "new_thread" kind then
        [ modalHead "Create thread" "Start a longer conversation." 
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Category ID" ], input [ value model.modalUserIds, placeholder "Forum/category ID", onInput ModalUserIds ] [] ]
            , div [ class "field" ] [ label [] [ text "Title" ], input [ value model.modalTitle, placeholder "What is this about?", onInput ModalTitle ] [] ]
            , div [ class "field" ]
                [ label [] [ text "Body" ]
                , textarea [ id "compose", value model.modalBody, placeholder "Write the first post...", onInput ModalBody ] []
                , div [ class "composer-footer modal-composer-footer" ]
                    [ button [ class "btn secondary attach-btn", type_ "button", title "Attach files or images", onClick (BridgeEvent "pick_attachments" E.null) ] [ text "＋ Attach" ]
                    , small [ class "muted" ] [ text ("Images, GIFs, and files up to " ++ formatBytesShort model.uploadMaxBytes ++ ".") ]
                    ]
                ]
            ]
        , modalActions "Create thread"
        ]
    else if kind == "new_forum" then
        [ modalHead "Create community" "Make a public r/community for focused discussions."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Community name" ], input [ value model.modalTitle, placeholder "Gaming, News, Art...", onInput ModalTitle ] [] ]
            , div [ class "field" ] [ label [] [ text "r/ slug" ], input [ value model.modalUserIds, placeholder "gaming", onInput ModalUserIds ] [] ]
            , div [ class "field" ] [ label [] [ text "Description" ], textarea [ value model.modalBody, placeholder "What should people post here?", onInput ModalBody ] [] ]
            ]
        , modalActions "Create community"
        ]
    else if kind == "new_dm" then
        [ modalHead "New message" "Start a DM or group chat by username."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Usernames" ], input [ value model.modalUserIds, placeholder "alice, bob, charlie", onInput ModalUserIds, attribute "autocomplete" "off" ] [] ]
            , div [ class "field" ] [ label [] [ text "Group name optional" ], input [ value model.modalTitle, placeholder "Leave blank for a 1:1 DM", onInput ModalTitle ] [] ]
            , p [ class "muted modal-hint" ] [ text "Separate usernames with commas. You can include or omit the @ sign." ]
            ]
        , modalActions "Start chat"
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
            serverId = String.toInt (String.dropLeft 8 kind) |> Maybe.withDefault 0
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
            selectedCategory = String.toInt (String.trim model.modalUserIds)
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
        [ modalHead "Join a Server" "Enter an invite code to join."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Invite code" ], input [ value model.modalUserIds, placeholder "e.g. abc123", onInput ModalUserIds ] [] ]
            ]
        , modalActions "Join"
        ]

    else if String.startsWith "invite:" kind then
        let
            serverId = String.toInt (String.dropLeft 7 kind) |> Maybe.withDefault 0
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
            selectedChannel = String.toInt (String.trim model.modalUserIds)
            channelChoices =
                choiceCard (selectedChannel == Nothing) "S" "Server home" "Let friends choose where to begin." (SetModalChoice "user_ids" "")
                    :: List.map
                        (\channel ->
                            choiceCard
                                (selectedChannel == Just channel.id)
                                (if channel.kind == "voice" then "♪" else "#")
                                channel.name
                                (if channel.kind == "voice" then "Open this voice room" else "Open this text channel")
                                (SetModalChoice "user_ids" (String.fromInt channel.id))
                        )
                        channels
        in
        [ modalHead "Invite friends" "Choose where the invite opens, then copy one secure link."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Open invite in" ], div [ class "choice-grid invite-destination-grid" ] channelChoices ]
            , div [ class "field" ]
                [ label [] [ text "Usage limit" ]
                , div [ class "segmented-choice" ]
                    [ choicePill (model.modalBody == "0") "Unlimited" (SetModalChoice "body" "0")
                    , choicePill (model.modalBody == "1") "One use" (SetModalChoice "body" "1")
                    , choicePill (model.modalBody == "10") "10 uses" (SetModalChoice "body" "10")
                    , choicePill (model.modalBody == "25") "25 uses" (SetModalChoice "body" "25")
                    ]
                ]
            , p [ class "muted modal-hint" ] [ text "Plainwire reuses an equivalent active invite, so repeated clicks do not create clutter." ]
            ]
        , modalActions "Copy invite"
        ]
    else if String.startsWith "edit_server:" kind then
        [ modalHead "Customize server" "Give this server its own identity across desktop and mobile."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Server name" ], input [ value model.modalTitle, maxlength 80, placeholder "Server name", onInput ModalTitle ] [] ]
            , div [ class "field" ] [ label [] [ text "Description" ], textarea [ value model.modalBody, maxlength 280, placeholder "What is this server for?", onInput ModalBody ] [] ]
            , div [ class "field" ]
                [ label [] [ text "Server icon" ]
                , input [ value model.modalUserIds, placeholder "Upload an image or paste a URL", onInput ModalUserIds ] []
                , div [ class "file-picker-row" ]
                    [ input [ id "serverIconFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "serverIconFile")) ] []
                    , label [ class "btn secondary file-picker-button", attribute "for" "serverIconFile" ] [ text "Choose icon" ]
                    , small [ class "muted" ] [ text "JPEG, PNG, GIF, WebP, or AVIF" ]
                    ]
                ]
            , div [ class "field" ]
                [ label [] [ text "Server banner" ]
                , input [ value model.modalBannerUrl, placeholder "Upload an image or paste a URL", onInput ModalBannerUrl ] []
                , div [ class "file-picker-row" ]
                    [ input [ id "serverBannerFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "serverBannerFile")) ] []
                    , label [ class "btn secondary file-picker-button", attribute "for" "serverBannerFile" ] [ text "Choose banner" ]
                    , small [ class "muted" ] [ text "JPEG, PNG, GIF, WebP, or AVIF" ]
                    ]
                ]
            , div [ class "field server-color-field" ]
                [ label [] [ text "Accent color" ]
                , div [ class "server-color-control" ]
                    [ input [ type_ "color", value model.modalAccentColor, onInput ModalAccentColor, attribute "aria-label" "Server accent color" ] []
                    , input [ value model.modalAccentColor, placeholder "#5865f2", maxlength 7, onInput ModalAccentColor ] []
                    ]
                , div [ class "accent-swatches", attribute "aria-label" "Suggested accent colors" ]
                    (List.map
                        (\color ->
                            button
                                [ type_ "button", class ("accent-swatch" ++ if model.modalAccentColor == color then " active" else "")
                                , style "background-color" color
                                , onClick (SetModalChoice "accent" color)
                                , attribute "aria-label" ("Use " ++ color)
                                ] []
                        )
                        [ "#5865f2", "#3b82f6", "#14b8a6", "#22c55e", "#eab308", "#f97316", "#ec4899", "#8b5cf6" ]
                    )
                ]
            ]
        , modalActions "Save server"
        ]
    else if String.startsWith "create_category:" kind then
        [ modalHead "Create category" "Group related channels in the server sidebar."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Category name" ], input [ value model.modalTitle, maxlength 40, placeholder "Games, Projects, Social…", onInput ModalTitle ] [] ]
            , div [ class "category-preview" ]
                [ span [] [ text "▾" ]
                , b [] [ text (if String.isEmpty (String.trim model.modalTitle) then "NEW CATEGORY" else String.toUpper (String.trim model.modalTitle)) ]
                , span [ class "muted" ] [ text "# channel" ]
                ]
            ]
        , modalActions "Create category"
        ]
    else if String.startsWith "edit_category:" kind then
        let
            ids = String.split ":" (String.dropLeft 14 kind)
            serverId = listAt 0 ids |> Maybe.andThen String.toInt |> Maybe.withDefault 0
            categoryId = listAt 1 ids |> Maybe.andThen String.toInt |> Maybe.withDefault 0
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
        [ modalHead "Add people" "Invite existing Plainwire users to this group."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Usernames" ], input [ value model.modalUserIds, maxlength 800, placeholder "alice, bob, charlie", onInput ModalUserIds, attribute "autocomplete" "off" ] [] ]
            , p [ class "muted modal-hint" ] [ text "Separate usernames with commas. The group supports up to 50 members." ]
            ]
        , modalActions "Add people"
        ]
    else if String.startsWith "invite_result:" kind then
        let rest = String.dropLeft 14 kind
            parts = String.split ":" rest
            url = Maybe.withDefault "" (listAt 1 parts)
            displayLink = url
        in if String.startsWith "error" rest then
            [ modalHead "Invite failed" "Could not create invite."
            , div [ class "modal-actions" ] [ button [ class "btn", onClick CloseModal ] [ text "Close" ] ]
            ]
           else
            [ modalHead "Invite created" "Share this link with friends."
            , div [ class "modal-body" ]
                [ div [ class "field" ]
                    [ label [] [ text "Invite link" ]
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

modalHead : String -> String -> Html Msg
modalHead title subtitle =
    div [ class "modal-head" ]
        [ div [] [ h2 [] [ text title ], p [ class "muted" ] [ text subtitle ] ]
        , button [ class "btn ghost", onClick CloseModal ] [ text "×" ]
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
        , class ("choice-card" ++ if selected then " selected" else "")
        , onClick msg
        , attribute "aria-pressed" (if selected then "true" else "false")
        ]
        [ span [ class "choice-card-icon" ] [ text icon ]
        , span [ class "choice-card-copy" ]
            [ b [] [ text heading ]
            , small [ class "muted" ] [ text copy ]
            ]
        , span [ class "choice-card-check", attribute "aria-hidden" "true" ] []
        ]

themeChoiceCard : Bool -> String -> String -> String -> Msg -> Html Msg
themeChoiceCard selected theme heading copy msg =
    button
        [ type_ "button"
        , class ("choice-card theme-choice" ++ if selected then " selected" else "")
        , onClick msg
        , attribute "aria-pressed" (if selected then "true" else "false")
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

choicePill : Bool -> String -> Msg -> Html Msg
choicePill selected label msg =
    button
        [ type_ "button"
        , class ("choice-pill" ++ if selected then " selected" else "")
        , onClick msg
        , attribute "aria-pressed" (if selected then "true" else "false")
        ]
        [ text label ]

ctxItemView : Int -> CtxItem -> Html Msg
ctxItemView idx item =
    div [ class ("ctx-item" ++ (if item.danger then " ctx-danger" else "") ++ (if item.sep then " ctx-sep-before" else "")), onClick (CtxAction idx) ]
        [ span [ class "ctx-icon" ] [ text (Maybe.withDefault "" item.icon) ]
        , span [] [ text item.label ]
        ]

messageContext : Maybe User -> Message -> Int -> Int -> ContextMenu
messageContext me message x y =
    let mine = case me of
            Just user -> user.id == message.userId
            Nothing -> False
        base =
            [ { label = "Reply", icon = Just "↩", danger = False, sep = False, msg = SetReplyTo message }
            , { label = "Copy text", icon = Just "⧉", danger = False, sep = False, msg = CopyText message.body }
            ]
        authorItems = if mine then [] else
            [ { label = "View author profile", icon = Just "○", danger = False, sep = True, msg = Go ("#profile/" ++ String.fromInt message.userId) }
            , { label = "Copy author username", icon = Just "@", danger = False, sep = False, msg = CopyText ("@" ++ message.username) }
            ]
        mineItems = if mine then [ { label = "Delete message", icon = Just "×", danger = True, sep = True, msg = DeleteMessage message.id } ] else []
    in { items = base ++ authorItems ++ mineItems, x = x, y = y }

conversationContext : Conversation -> Int -> Int -> ContextMenu
conversationContext c x y =
    let closeItem =
            if c.memberCount > 2 then
                { label = "Leave group", icon = Just "×", danger = True, sep = True, msg = LeaveConversation c.id }
            else
                { label = "Close", icon = Just "×", danger = False, sep = True, msg = CloseConversation c.id }
    in
    { items =
        [ { label = "Open", icon = Just "→", danger = False, sep = False, msg = Go ("#dm/" ++ String.fromInt c.id) }
        , { label = "Mark read", icon = Just "✓", danger = False, sep = False, msg = MarkConvRead c.id }
        , { label = "Rename", icon = Just "✎", danger = False, sep = False, msg = EditConversationModal c }
        , { label = "Add people", icon = Just "+", danger = False, sep = False, msg = AddPeopleModal c.id }
        , closeItem
        ]
      , x = x, y = y
      }

userContext : Model -> User -> Int -> Int -> ContextMenu
userContext model user x y =
    let isSelf = Maybe.map .id model.me == Just user.id
        relationship = List.filter (\friend -> friend.user.id == user.id) model.friends |> List.head
        blocked = Maybe.map .status relationship == Just "blocked"
        blockedByMe = Maybe.map .blockedByMe relationship == Just True
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
    in { items = actions, x = x, y = y }

onContextMenu : (Int -> Int -> Msg) -> Attribute Msg
onContextMenu toMsg =
    custom "contextmenu"
        (D.map2
            (\x y -> { message = toMsg x y, stopPropagation = True, preventDefault = True })
            (D.field "clientX" D.int)
            (D.field "clientY" D.int)
        )

stopClick : Attribute Msg
stopClick =
    custom "click" (D.succeed { message = NoOp, stopPropagation = True, preventDefault = False })

onClickStop : Msg -> Attribute Msg
onClickStop msg =
    custom "click" (D.succeed { message = msg, stopPropagation = True, preventDefault = True })

renderCallLayer : Model -> Html Msg
renderCallLayer model =
    let popups = List.filterMap identity
            [ Maybe.map (\i -> renderCallPopup "incoming" i model) model.callUI.incoming
            , Maybe.map (\o -> renderCallPopup "outgoing" o model) model.callUI.outgoing
            ]
        activeOverlay = case model.callUI.active of
            Just active ->
                let joinedCall = isJoinedCall active.conversationId model
                in if not joinedCall || model.callMode == Ringing || model.callMode == Calling then
                    []
                else if active.expanded then
                    [ renderExpandedCallOverlay active model ]
                else
                    [ renderCompactCallBar active model ]
            _ -> []
    in if List.isEmpty popups && List.isEmpty activeOverlay then text ""
       else div [ class "call-layer" ] (popups ++ activeOverlay)

renderCallPopup : String -> CallPopup -> Model -> Html Msg
renderCallPopup kind popup model =
    let avatarHtml = avatarImg popup.avatarUrl popup.displayName "big"
        actions = case kind of
            "incoming" ->
                div [ class "call-popup-actions" ]
                    [ button [ class "btn call-decline", onClick (DeclineCall popup.conversationId) ] [ text "Decline" ]
                    , button [ class "btn call-accept", onClick (AcceptCall popup.conversationId) ] [ text "Accept" ]
                    ]
            "outgoing" ->
                div [ class "call-popup-actions" ]
                    [ button [ class "btn call-decline", onClick (BridgeEvent "cancel_call" (E.int popup.conversationId)) ] [ text "Cancel" ]
                    ]
            _ -> text ""
    in div [ class ("call-popup " ++ kind) ]
        [ div [ class "call-popup-head", attribute "data-call-drag-handle" "true" ]
            [ div [ class "call-avatar-wrap" ]
                [ avatarHtml ]
            , div []
                [ p [ class "call-popup-title" ] [ text popup.displayName ]
                , p [ class "call-popup-sub" ] [ text (if kind == "incoming" then "Incoming call" else "Calling...") ]
                ]
            ]
        , actions
        ]

renderCompactCallBar : ActiveCall -> Model -> Html Msg
renderCompactCallBar active model =
    let
        myId = Maybe.map .id model.me
        remoteUsers = List.filter (\user -> Just user.userId /= myId) active.users
        count = List.length active.users
        connectedCount = List.length (List.filter .connected remoteUsers)
        failedCount = List.length (List.filter .connectionFailed remoteUsers)
        countText =
            if List.isEmpty remoteUsers then
                "Waiting for others"
            else if failedCount > 0 then
                "Audio failed · Open to retry"
            else if connectedCount == List.length remoteUsers then
                "Audio connected · " ++ String.fromInt count ++ " participant" ++ (if count /= 1 then "s" else "")
            else
                "Connecting audio · " ++ String.fromInt connectedCount ++ "/" ++ String.fromInt (List.length remoteUsers)
        userAvatars = List.take 3 active.users
            |> List.map (\u -> avatarImg u.avatarUrl u.displayName "small")
        overflow = count - 3
    in div [ class "call-bar compact" ]
        [ div
            [ class "call-bar-drag-area"
            , attribute "data-call-drag-handle" "true"
            , title "Open call details"
            , onClick ToggleCallOverlay
            ]
            [ div [ class "call-bar-icon" ] [ callIcon "audio" ]
            , div [ class "call-bar-info" ]
                [ span [ class "call-bar-title" ] [ text "Voice call" ]
                , span [ class "call-bar-sub" ] [ text countText ]
                ]
            , div [ class "call-bar-avatars" ] (userAvatars ++
                (if overflow > 0 then [ div [ class "avatar small" ] [ text ("+" ++ String.fromInt overflow) ] ] else [])
              )
            ]
        , div [ class "call-bar-controls", attribute "aria-label" "Call controls" ]
            [ button [ class ("btn icon-btn" ++ if model.voice.muted then " call-muted" else ""), title (if model.voice.muted then "Unmute" else "Mute"), onClickStop (BridgeEvent "toggle_mute" E.null) ]
                [ callIcon (if model.voice.muted then "mic off" else "mic") ]
            , button [ class ("btn icon-btn" ++ if model.voice.deafened then " call-muted" else ""), title (if model.voice.deafened then "Undeafen" else "Deafen"), onClickStop (BridgeEvent "toggle_deafen" E.null) ]
                [ callIcon (if model.voice.deafened then "audio off" else "audio") ]
            , if model.voice.screenShare then
                button [ class "btn icon-btn share-active", title "Stop sharing", onClickStop StopScreenShare ]
                    [ callIcon "screen off" ]
              else
                button [ class "btn icon-btn", title "Share screen", onClickStop StartScreenShare ]
                    [ callIcon "screen" ]
            , button [ class "btn icon-btn call-decline", title "Leave call", onClickStop EndCall ]
                [ callIcon "close" ]
            ]
        ]

callIcon : String -> Html Msg
callIcon kind =
    span [ class ("call-icon call-icon-" ++ String.replace " " " call-icon-" kind), attribute "aria-hidden" "true" ] []


renderExpandedCallOverlay : ActiveCall -> Model -> Html Msg
renderExpandedCallOverlay active model =
    let duration = floor (toFloat (model.serverTime - active.startTime) / 1000)
        minutes = String.fromInt (duration // 60)
        seconds = String.fromInt (modBy 60 duration) |> String.padLeft 2 '0'
        timerText = minutes ++ ":" ++ seconds
    in div [ class "call-overlay expanded" ]
        [ div [ class "call-overlay-header", attribute "data-call-drag-handle" "true" ]
            [ div [ class "call-overlay-heading" ]
                [ div [ class "call-overlay-title" ]
                    [ span [ class "call-overlay-icon" ] [ callIcon "audio" ]
                    , span [] [ text "Voice call" ]
                    ]
                , div [ class "call-overlay-meta" ]
                    [ span [ class "call-connection-dot", attribute "aria-hidden" "true" ] []
                    , span [] [ text (String.fromInt (List.length active.users) ++ " participants") ]
                    , span [ attribute "aria-hidden" "true" ] [ text "·" ]
                    , span
                        [ class "call-overlay-timer pw-live-call-timer"
                        , attribute "data-call-start" (String.fromInt active.startTime)
                        ]
                        [ text timerText ]
                    ]
                ]
            , button [ class "btn icon-btn call-minimize", title "Minimize call", onClick ToggleCallOverlay ]
                [ span [ class "call-minimize-icon", attribute "aria-hidden" "true" ] [] ]
            ]
        , if model.turnLimitReached then
            div [ class "call-turn-limit-row" ]
                [ callIcon "audio off"
                , span [] [ text "GB limit reached, TURN disabled until next month." ]
                ]
          else
            text ""
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
                [ div [ class "call-empty" ] [ text "Connecting audio..." ] ]
             else
                List.map (renderCallUser model) active.users)
        , div [ class "call-overlay-controls", attribute "aria-label" "Call controls" ]
            [ button [ class ("call-control" ++ if model.voice.muted then " active danger" else ""), onClick (BridgeEvent "toggle_mute" E.null) ]
                [ callIcon (if model.voice.muted then "mic off" else "mic"), span [] [ text (if model.voice.muted then "Unmute" else "Mute") ] ]
            , button [ class ("call-control" ++ if model.voice.deafened then " active danger" else ""), onClick (BridgeEvent "toggle_deafen" E.null) ]
                [ callIcon (if model.voice.deafened then "audio off" else "audio"), span [] [ text (if model.voice.deafened then "Undeafen" else "Deafen") ] ]
            , if model.voice.screenShare then
                button [ class "call-control active", onClick StopScreenShare ] [ callIcon "screen off", span [] [ text "Stop share" ] ]
              else
                button [ class "call-control", onClick StartScreenShare ] [ callIcon "screen", span [] [ text "Share" ] ]
            , button [ class "call-control", onClick (BridgeEvent "unlock_audio" E.null) ] [ callIcon "audio", span [] [ text "Resume audio" ] ]
            , button [ class "call-control", onClick (BridgeEvent "toggle_speaker" E.null) ] [ callIcon "audio", span [] [ text "Speaker" ] ]
            , button [ class "call-control danger leave", onClick EndCall ] [ callIcon "close", span [] [ text "Leave" ] ]
            ]
        ]

renderCallUser : Model -> CallUser -> Html Msg
renderCallUser model u =
    let
        isSelf = Maybe.map .id model.me == Just u.userId
        avatarClass = "small" ++ if (u.connected || isSelf) && not u.muted then " live" else ""
        statusText =
            if u.reconnecting then
                "Reconnecting"
            else if u.connectionFailed then
                "Audio connection failed"
            else if u.muted then
                "Muted"
            else if u.deafened then
                "Deafened"
            else if isSelf then
                "You · Ready"
            else if u.connected then
                "Connected to you"
            else
                "Connecting audio"
        retryButton =
            if u.connectionFailed && not isSelf then
                button [ class "btn secondary call-retry", onClick (RetryCallPeer u.userId) ] [ text "Retry audio" ]
            else
                text ""
    in div [ class "call-user-row" ]
        [ avatarImg u.avatarUrl u.displayName avatarClass
        , div [ class "call-user-info" ]
            [ span [ class "call-user-name" ] [ text u.displayName ]
            , span [ class ("call-user-status" ++ if u.connectionFailed then " failed" else if u.reconnecting then " reconnecting" else if u.muted then " muted" else if u.deafened then " deafened" else "") ]
                [ text statusText ]
            ]
        , retryButton
        ]


avatarColor : String -> String
avatarColor name =
    let
        palette = [ "#5865f2", "#3b82f6", "#16877a", "#37854f", "#9a6716", "#b64d6b", "#7c5bb5", "#a75432" ]
        code =
            case String.uncons (String.toLower name) of
                Just ( first, _ ) -> Char.toCode first
                Nothing -> 0
        index = modBy (List.length palette) code
    in
    listAt index palette |> Maybe.withDefault "#5865f2"


avatarImg : String -> String -> String -> Html Msg
avatarImg url name cls =
    if String.isEmpty url then
        div [ class ("avatar " ++ cls), style "background-color" (avatarColor name), style "color" "#ffffff" ]
            [ text (String.left 1 (String.toUpper name)) ]
    else
        img
            [ class ("avatar " ++ cls)
            , src url
            , alt (name ++ " avatar")
            , attribute "decoding" "async"
            , attribute "loading" "lazy"
            , attribute "data-avatar-fallback" (String.left 1 (String.toUpper name))
            , attribute "data-avatar-src" url
            ]
            []


presenceAvatar : Dict String String -> Int -> String -> String -> String -> Html Msg
presenceAvatar statuses userId url name cls =
    let presence = statusClass statuses userId
        label = case presence of
            "away" -> "Away"
            "busy" -> "Busy"
            "online" -> "Online"
            _ -> "Offline"
    in div [ class "presence-avatar", title label, attribute "aria-label" (name ++ "  -  " ++ label) ]
        [ avatarImg url name cls
        , span [ class ("avatar-presence-dot " ++ presence), attribute "aria-hidden" "true" ] []
        ]


-- AUTH VIEW

renderAuth : Model -> Html Msg
renderAuth model =
    div [ class "auth-shell" ]
        [ section [ class "auth-brand-panel" ]
            [ div [ class "auth-brand-lockup" ] [ div [ class "auth-brand-mark" ] [], span [] [ text model.appName ] ]
            , div [ class "auth-brand-copy" ]
                [ span [ class "eyebrow" ] [ text "Plainwire" ]
                , h1 [] [ text "Talk without the clutter." ]
                , p [] [ text (if String.isEmpty model.instanceDescription then "Messages, calls, communities, and files on one self-hosted server." else model.instanceDescription) ]
                ]
            , div [ class "auth-capabilities", attribute "aria-label" "Plainwire features" ]
                [ span [] [ text "Messages" ]
                , span [] [ text "Voice" ]
                , span [] [ text "Screen sharing" ]
                , span [] [ text "Forums" ]
                , span [] [ text "Files" ]
                ]
            ]
        , main_ [ class "auth-form-panel" ]
            [ div [ class "auth-form-wrap" ]
                [ div [ class "auth-mobile-brand" ] [ div [ class "auth-brand-mark" ] [], b [] [ text model.appName ] ]
                , div [ class "auth-heading" ]
                    [ h2 [] [ text (if model.authMode == "login" then "Sign in to " ++ model.appName else "Create your account") ]
                    , p [ class "muted" ] [ text (if model.authMode == "login" then "Sign in to continue to your conversations." else "Set up an account on this Plainwire instance.") ]
                    ]
                , div [ class ("auth-mode-switch" ++ if model.registrationEnabled then "" else " single"), attribute "role" "tablist" ]
                    [ button [ class ("auth-mode-btn" ++ if model.authMode == "login" then " active" else ""), onClick (AuthMode "login") ] [ text "Sign in" ]
                    , if model.registrationEnabled then
                        button [ class ("auth-mode-btn" ++ if model.authMode == "register" then " active" else ""), onClick (AuthMode "register") ] [ text "Register" ]
                      else
                        text ""
                    ]
                , Html.form [ class "auth-fields", onSubmit DoAuth ]
                    [ div [ class "field" ]
                        [ label [ attribute "for" "u" ] [ text "Username" ]
                        , input [ id "u", type_ "text", attribute "autocomplete" "username", attribute "autocapitalize" "none", attribute "spellcheck" "false", maxlength 24, placeholder "yourname", value model.authUsername, onInput AuthUsername ] []
                        ]
                    , if model.authMode == "register" then
                        div [ class "field" ]
                            [ label [ attribute "for" "d" ] [ text "Display name" ]
                            , input [ id "d", type_ "text", attribute "autocomplete" "name", maxlength 48, placeholder "How people see you", value model.authDisplayName, onInput AuthDisplayName ] []
                            ]
                      else text ""
                    , div [ class "field" ]
                        [ label [ attribute "for" "p" ] [ text "Password" ]
                        , div [ class "auth-password-field" ]
                            [ input
                                [ id "p"
                                , type_ (if model.authPasswordVisible then "text" else "password")
                                , attribute "autocomplete" (if model.authMode == "login" then "current-password" else "new-password")
                                , maxlength 256
                                , value model.authPassword
                                , onInput AuthPassword
                                ] []
                            , button
                                [ type_ "button"
                                , class "auth-password-toggle"
                                , onClick ToggleAuthPasswordVisibility
                                , attribute "aria-label" (if model.authPasswordVisible then "Hide password" else "Show password")
                                ]
                                [ text (if model.authPasswordVisible then "Hide" else "Show") ]
                            ]
                        ]
                    , if model.authMode == "register" then
                        div [ class "auth-password-meter" ]
                            [ div [ class ("auth-password-bar strength-" ++ authPasswordStrength model.authPassword) ] []
                            , small [ class "muted" ] [ text "Use at least 10 characters. A longer unique passphrase is best." ]
                            ]
                      else text ""
                    , if model.authMode == "register" then
                        div [ class "field" ]
                            [ label [ attribute "for" "pc" ] [ text "Confirm password" ]
                            , input
                                [ id "pc"
                                , type_ (if model.authPasswordVisible then "text" else "password")
                                , attribute "autocomplete" "new-password"
                                , maxlength 256
                                , value model.authPasswordConfirm
                                , onInput AuthPasswordConfirm
                                ] []
                            ]
                      else text ""
                    , case authValidationError { model | authBusy = False } of
                        Just err -> div [ class "auth-error", attribute "role" "alert" ] [ text err ]
                        Nothing -> text ""
                    , button [ type_ "submit", class "btn auth-submit", disabled (model.authBusy || not (authReady model)) ]
                        [ text (if model.authBusy then "Working..." else if model.authMode == "login" then "Sign in" else "Create account") ]
                    ]
                , p [ class "auth-footnote" ]
                    [ text (if model.registrationEnabled then "This is a self-hosted Plainwire server." else "Registration is closed on this server. Sign in with an existing account.") ]
                , div [ class "auth-instance-meta" ]
                    [ span [] [ text ("Plainwire " ++ model.clientVersion) ]
                    , span [ attribute "aria-hidden" "true" ] [ text "·" ]
                    , span [] [ text "Web client" ]
                    ]
                ]
            ]
        ]

authPasswordStrength : String -> String
authPasswordStrength password =
    let n = String.length password
    in if n >= 16 then "strong" else if n >= 10 then "medium" else "weak"


-- APP SHELL

renderApp : Model -> Html Msg
renderApp model =
    div [ class "layout", attribute "data-ui-version" "1.5.0" ]
        [ renderRail model
        , renderSideForRoute model
        , main_ [ class (mainClass model.active) ]
            [ renderTopbar model
            , div [ class (contentClass model.active) ] [ renderPage model ]
            ]
        , renderRightPanel model
        , div [ class ("drawer-overlay" ++ if model.sidebarOpen then " open" else "")
              , onClick CloseSidebar
              ] []
        , renderMobileNav model
        , renderServersSheet model
        , renderContextMenu model
        , renderModal model
        ]



mainClass : ActiveRoute -> String
mainClass active =
    case active of
        DmView _ -> "main route-chat"
        ChannelView _ -> "main route-chat"
        Settings -> "main route-settings"
        _ -> "main"

contentClass : ActiveRoute -> String
contentClass active =
    case active of
        DmView _ -> "content chat-content"
        ChannelView _ -> "content chat-content"
        _ -> "content"

renderServersSheet : Model -> Html Msg
renderServersSheet model =
    if not model.serversSheetOpen then text "" else
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
                    List.map (\s -> serverSheetRow s model) model.servers)
            , div [ class "servers-sheet-actions" ]
                [ button [ class "btn", onClick (Go "#new-server") ] [ text "Create server" ]
                , button [ class "btn secondary", onClick (InviteModal 0) ] [ text "Join with invite" ]
                ]
            ]
        ]

serverSheetRow : Server -> Model -> Html Msg
serverSheetRow s model =
    let isActive = case model.active of
            ServerView id -> id == s.id
            ChannelView _ -> Maybe.map (.id << .server) model.currentServer == Just s.id
            VoiceChannelView _ -> Maybe.map (.id << .server) model.currentServer == Just s.id
            _ -> False
    in button [ type_ "button"
              , class ("server-sheet-row" ++ if isActive then " active" else "")
              , onClick (Go ("#server/" ++ String.fromInt s.id))
              , attribute "aria-current" (if isActive then "page" else "false")
              ]
        [ serverIcon s
        , div [ class "grow" ]
            [ b [] [ text s.name ]
            , small [] [ text (s.role ++ " · " ++ String.fromInt s.memberCount ++ " members") ]
            ]
        ]


renderRail : Model -> Html Msg
renderRail model =
    let
        serverButtons = List.map (\server -> renderServerIcon server model) (List.take 8 model.servers)
        moreServers =
            if List.length model.servers > 8 then
                [ railBtn "servers" "More servers" model.serversSheetOpen ToggleServersSheet ]
            else
                []
    in
    nav [ class "rail", attribute "aria-label" "Main navigation" ]
        ([ div [ class "mark", title model.appName, attribute "aria-label" model.appName ] []
         , railBtn "home" "Home" (model.active == Home) (Go "#")
         , railBtn "messages" "Direct messages" (isDmActive model) (Go "#dms")
         , railBtn "forums" "Forums" (model.active == Forums) (Go "#forums")
         , railBtn "friends" "Friends" (model.active == Friends) (Go "#friends")
         , div [ class "rail-divider", attribute "aria-hidden" "true" ] []
         ] ++ serverButtons ++ moreServers
         ++ [ div [ class "rail-spacer" ] []
            , railBtn "settings" "Settings" (model.active == Settings) (Go "#settings")
            ])

railBtn : String -> String -> Bool -> Msg -> Html Msg
railBtn icon label active msg =
    button [ class ("rail-btn" ++ if active then " active" else "")
           , onClick msg
           , title label
           , attribute "aria-label" label
           ]
        [ span [ class ("rail-glyph ui-icon ui-icon-" ++ icon), attribute "aria-hidden" "true" ] [] ]

isDmActive : Model -> Bool
isDmActive model = case model.active of
    Dms -> True
    DmView _ -> True
    _ -> False

renderServerIcon : Server -> Model -> Html Msg
renderServerIcon s model =
    let isActive = serverIsActive s model
    in button [ class ("rail-btn" ++ if isActive then " active" else "")
              , onClick (Go ("#server/" ++ String.fromInt s.id))
              , title s.name
              , attribute "aria-label" s.name
              , attribute "aria-current" (if isActive then "page" else "false")
              ]
        [ serverIcon s ]

serverIsActive : Server -> Model -> Bool
serverIsActive server model =
    case model.active of
        ServerView id -> id == server.id
        ChannelView _ -> Maybe.map .server model.currentServer == Just server
        VoiceChannelView _ -> Maybe.map .server model.currentServer == Just server
        _ -> False

serverIcon : Server -> Html Msg
serverIcon s =
    if String.isEmpty s.iconUrl then
        div [ class "server-icon" ] [ text (String.left 1 (String.toUpper s.name)) ]
    else
        div [ class "server-icon" ] [ img [ src s.iconUrl, alt s.name ] [] ]


renderSide : Model -> Html Msg
renderSide model =
    aside [ class ("side" ++ if model.sidebarOpen then " open" else "") ]
        [ sideHead model
        , searchBox model
        , div [ class "list" ]
            ([ notifRow model
             , friendsRow model
             , dmHeader model
             ]
             ++ (let requestCount = List.length (List.filter (\c -> c.requestState == "pending") model.convs)
                 in if requestCount == 0 then [] else [ messageRequestsNav requestCount ])
             ++ List.map (\c -> convRow c model) (List.filter (\c -> c.requestState /= "pending") model.convs))
        , userPanel model
        ]

renderSideForRoute : Model -> Html Msg
renderSideForRoute model =
    case ( model.active, model.currentServer ) of
        ( ServerView _, Just data ) -> renderServerSide model data
        ( ChannelView _, Just data ) -> renderServerSide model data
        ( VoiceChannelView _, Just data ) -> renderServerSide model data
        _ -> renderSide model

renderServerSide : Model -> ServerData -> Html Msg
renderServerSide model data =
    let textChannels = List.filter (\c -> c.kind /= "voice") data.channels
        voiceChannels = List.filter (\c -> c.kind == "voice") data.channels
        uncategorizedText = List.filter (\c -> c.categoryId == Nothing) textChannels
        uncategorizedVoice = List.filter (\c -> c.categoryId == Nothing) voiceChannels
        isCollapsed catId = Set.member catId model.collapsedCategories
        categoryBlock cat channels =
            [ div [ class "channel-group-title clickable", onClick (ToggleCategory cat.id) ]
                [ text (if isCollapsed cat.id then "▶ " else "▼ ")
                , text cat.name
                , if canManage then
                    span [ class "category-actions" ]
                        [ button [ class "ctx-trigger", type_ "button", title ("Add a channel to " ++ cat.name), onClickStop (ChannelModalInCategory data.server.id cat.id) ] [ text "+" ]
                        , button [ class "ctx-trigger", type_ "button", title ("Edit " ++ cat.name), onClickStop (EditCategoryModal data.server.id cat) ] [ text "⋯" ]
                        ]
                  else text ""
                ]
            ] ++
                (if isCollapsed cat.id then
                    []
                 else if List.isEmpty channels then
                    [ div [ class "category-empty" ] [ text "No channels yet" ] ]
                 else
                    List.map (managedChannelRow canManage data.categories) channels
                )
        sortedCategories = List.sortBy .position data.categories
        canManage = data.server.role == "owner" || data.server.role == "admin"
    in
    aside [ class ("side" ++ if model.sidebarOpen then " open" else "") ]
        [ div [ class "side-head server-side-head" ]
            [ div [ class "side-title-row" ]
                [ div [ class "server-side-identity" ]
                    [ serverIcon data.server
                    , div [ class "side-title-copy" ]
                        [ h1 [] [ text data.server.name ]
                        , small [] [ text (if String.isEmpty data.server.description then "Server" else data.server.description) ]
                        ]
                    ]
                , button [ class "side-close", type_ "button", onClick CloseSidebar, attribute "aria-label" "Close navigation" ]
                    [ span [ class "call-icon call-icon-close", attribute "aria-hidden" "true" ] [] ]
                ]
            , div [ class "nav-actions" ]
                (if canManage then
                    [ button [ class "btn secondary", onClick (InviteModal data.server.id) ] [ text "Invite" ]
                    , button [ class "btn secondary", onClick (ChannelModal data.server.id) ] [ text "Channel" ]
                    , button [ class "btn secondary", onClick (CreateCategoryModal data.server.id) ] [ text "Category" ]
                    , button [ class "btn secondary", onClick (EditServerModal data.server) ] [ text "Edit" ]
                    ]
                 else
                    []
                )
            ]
        , div [ class "list server-channel-list" ]
            (channelGroup "Text channels" uncategorizedText
             ++ channelGroup "Voice channels" uncategorizedVoice
             ++ List.concatMap (\cat -> categoryBlock cat (List.filter (\c -> c.categoryId == Just cat.id) data.channels)) sortedCategories)
        , userPanel model
        ]

channelGroup : String -> List Channel -> List (Html Msg)
channelGroup heading channels =
    if List.isEmpty channels then
        []
    else
        div [ class "channel-group-title" ] [ text heading ] :: List.map channelRow channels

statusClass : Dict String String -> Int -> String
statusClass userStatuses uid =
    case Dict.get (String.fromInt uid) userStatuses of
        Just "busy" -> "busy"
        Just "away" -> "away"
        Just "invisible" -> "invisible"
        Just _ -> "online"
        Nothing -> "offline"

statusPreference : String -> String
statusPreference status =
    case status of
        "away" -> "away"
        "busy" -> "busy"
        "invisible" -> "invisible"
        _ -> "online"

renderRightPanel : Model -> Html Msg
renderRightPanel model =
    case ( model.active, model.currentServer ) of
        ( ServerView _, Just data ) -> renderMembersPanel model.userStatuses data.members
        ( ChannelView _, Just data ) -> renderMembersPanel model.userStatuses data.members
        ( VoiceChannelView _, Just data ) -> renderMembersPanel model.userStatuses data.members
        _ -> text ""

renderMembersPanel : Dict String String -> List ServerMember -> Html Msg
renderMembersPanel userStatuses members =
    aside [ class "right members-panel" ]
        [ h3 [] [ text "Members" ]
        , div [ class "list" ] (List.map (\m -> memberRow userStatuses m) members)
        ]

sideHead : Model -> Html Msg
sideHead model =
    div [ class "side-head" ]
        [ div [ class "side-title-row" ]
            [ div [ class "side-title-copy" ]
                [ h1 [] [ text model.appName ]
                , small [] [ text "Communities, direct messages, and calls" ]
                ]
            , button [ class "side-close", type_ "button", onClick CloseSidebar, attribute "aria-label" "Close navigation" ]
                [ span [ class "call-icon call-icon-close", attribute "aria-hidden" "true" ] [] ]
            ]
        , div [ class "nav-actions" ]
            [ button [ class "btn secondary", onClick (Go "#new-server") ] [ text "Create server" ]
            , button [ class "btn secondary", onClick (InviteModal 0) ] [ text "Join with invite" ]
            ]
        ]

searchBox : Model -> Html Msg
searchBox _ =
    div [ class "search" ]
        [ input [ id "globalSearch", placeholder "Search users and threads"
                , onInput (\s -> SearchQuery s)
                , on "keydown" (D.andThen (\k ->
                    if k == "Enter" then D.succeed DoSearch else D.fail "no")
                    (D.field "key" D.string))
                ] []
        ]

notifRow : Model -> Html Msg
notifRow model =
    let unread = List.length (List.filter (\n -> not n.seen) model.notifs)
    in a [ class "row", href "#notifications", onClick (Go "#notifications") ]
        [ span [ class "nav-symbol", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-notifications" ] [] ]
        , div [ class "grow" ]
            [ b [] [ text "Notifications" ]
            , small [ class "muted" ] [ text "Mentions and activity" ]
            ]
        , span [ class "badge", if unread == 0 then attribute "data-zero" "1" else attribute "data-zero" "0" ]
            [ if unread > 0 then text (String.fromInt unread) else text "" ]
        ]

friendsRow : Model -> Html Msg
friendsRow model =
    let pending = List.length (List.filter (\f -> f.incoming) model.friends)
    in a [ class "row", href "#friends", onClick (Go "#friends") ]
        [ span [ class "nav-symbol", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-friends" ] [] ]
        , div [ class "grow" ]
            [ b [] [ text "Friends" ], small [ class "muted" ] [ text "Requests and contacts" ] ]
        , if pending > 0 then span [ class "badge" ] [ text (String.fromInt pending) ] else text ""
        ]

serverRow : Server -> Model -> Html Msg
serverRow s model =
    let isActive = case model.active of
            ServerView id -> id == s.id
            _ -> False
    in a [ class ("row" ++ if isActive then " active" else "")
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
        , button [ class "btn secondary", onClick NewDmModal ] [ text "New" ]
        ]

messageRequestsNav : Int -> Html Msg
messageRequestsNav count =
    a [ class "row message-requests-nav", href "#dms", onClick (Go "#dms") ]
        [ span [ class "nav-symbol", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-messages" ] [] ]
        , div [ class "grow" ] [ b [] [ text "Message requests" ], small [ class "muted" ] [ text "Review before replying" ] ]
        , span [ class "badge" ] [ text (String.fromInt count) ]
        ]

convRow : Conversation -> Model -> Html Msg
convRow c model =
    let isActive = case model.active of
            DmView id -> id == c.id
            _ -> False
        lastText = Maybe.withDefault "No messages yet" c.lastBody
    in a [ class ("row dm-row" ++ (if isActive then " active" else "") ++ (if c.unread > 0 then " unread" else ""))
         , href ("#dm/" ++ String.fromInt c.id)
         , onClick (Go ("#dm/" ++ String.fromInt c.id))
         , onContextMenu (OpenConvCtx c)
         ]
        [ convAvatar model c
        , div [ class "grow" ]
            [ div [ class "dm-row-head" ]
                [ b [] [ text (convName c) ]
                , small [ class "muted" ] [ text (agoAt model.serverTime c.updatedAt) ]
                ]
            , small [ class "muted dm-preview" ] [ text lastText ]
            ]
        , span [ class "badge", if c.unread == 0 then attribute "data-zero" "1" else attribute "data-zero" "0" ]
            [ if c.unread > 0 then text (String.fromInt c.unread) else text "" ]
        ]

convName : Conversation -> String
convName c =
    if not (String.isEmpty c.name) then c.name
    else if c.memberCount == 2 && not (String.isEmpty c.peerName) then c.peerName
    else "Group DM " ++ String.fromInt c.id

convAvatar : Model -> Conversation -> Html Msg
convAvatar model c =
    if not (String.isEmpty c.avatarUrl) then
        img [ class "avatar", src c.avatarUrl, alt "" ] []
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
                        |> Maybe.withDefault (if model.wsConnected then model.profileStatus else "offline")
            in
            div [ class "user-panel" ]
                [ div [ class "presence-avatar", title (statusDisplayName liveStatus), attribute "aria-label" (u.displayName ++ "  -  " ++ statusDisplayName liveStatus) ]
                    [ avatarImg u.avatarUrl u.displayName ""
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
        "online" -> "Online"
        "away" -> "Away"
        "busy" -> "Do not disturb"
        "invisible" -> "Invisible"
        _ -> "Offline"


renderMobileNav : Model -> Html Msg
renderMobileNav model =
    let
        unreadDms = List.sum (List.map .unread model.convs)
        unreadNotifs = List.length (List.filter (\notification -> not notification.seen) model.notifs)
        pendingFriends = List.length (List.filter .incoming model.friends)
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
        ServerView _ -> True
        ChannelView _ -> True
        VoiceChannelView _ -> True
        _ -> False

isProfileRoute : ActiveRoute -> Bool
isProfileRoute route =
    case route of
        ProfileView _ -> True
        _ -> False

mobileBtn : String -> String -> Bool -> Msg -> Int -> Html Msg
mobileBtn icon label active msg badgeCount =
    button [ class ("mobile-nav-btn" ++ if active then " active" else "")
           , onClick msg
           , attribute "aria-label" (label ++ if badgeCount > 0 then ", " ++ String.fromInt badgeCount ++ " new" else "")
           ]
        [ span [ class "mobile-nav-icon-wrap" ]
            [ span [ class ("mobile-nav-icon ui-icon ui-icon-" ++ icon), attribute "aria-hidden" "true" ] []
            , if badgeCount > 0 then
                span [ class "mobile-nav-badge", attribute "aria-hidden" "true" ]
                    [ text (if badgeCount > 99 then "99+" else String.fromInt badgeCount) ]
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
        Home -> "Overview"
        Forums -> "Community discussions"
        ForumView _ -> "Community"
        ThreadView _ -> "Discussion"
        Dms -> "Private conversations"
        DmView _ -> "Direct conversation"
        Friends -> "Contacts and requests"
        ProfileView _ -> "User profile"
        Settings -> "Preferences"
        NewServer -> "New community"
        ServerView _ -> "Server overview"
        ChannelView _ -> "Text channel"
        VoiceChannelView _ -> "Voice channel"
        InviteView _ -> "Server invite"
        Notifications -> "Mentions and activity"
        SearchView _ -> "Search results"


topbarTitle : Model -> String
topbarTitle model = case model.active of
    Home -> "Home"
    Forums -> "Forums"
    ForumView _ -> "Forum"
    ThreadView _ -> "Thread"
    Dms -> "Direct Messages"
    DmView _ -> "Direct Message"
    Friends -> "Friends"
    ProfileView _ -> "Profile"
    Settings -> "Settings"
    NewServer -> "Create server"
    ServerView _ -> "Server"
    ChannelView _ -> "Channel"
    VoiceChannelView _ -> "Voice"
    InviteView _ -> "Invite"
    Notifications -> "Notifications"
    SearchView _ -> "Search"


renderPage : Model -> Html Msg
renderPage model = case model.active of
    Home -> renderHomePage model
    Forums -> renderForumsPage model
    ForumView id -> renderForumPage id model
    ThreadView id -> renderThreadPage id model
    Dms -> renderDmsPage model
    DmView id -> renderMessagePage ("direct:" ++ String.fromInt id) "Message conversation" model
    Friends -> renderFriendsPage model
    ProfileView id -> renderProfilePage model
    Settings -> renderSettingsPage model
    NewServer -> renderNewServerPage model
    ServerView id -> renderServerPage model
    ChannelView id -> renderMessagePage ("channel:" ++ String.fromInt id) "Message channel" model
    VoiceChannelView id -> renderVoicePage id model
    InviteView _ -> renderInvitePage model
    Notifications -> renderNotificationsPage model
    SearchView q -> renderSearchPage q model


renderHomePage : Model -> Html Msg
renderHomePage model =
    let
        unreadNotifs = List.length (List.filter (\n -> not n.seen) model.notifs)
        unreadDms = List.sum (List.map (\c -> c.unread) model.convs)
        recentConvs = List.take 5 (sortConvs model.convs)
        displayName =
            case model.me of
                Just user -> user.displayName
                Nothing -> "there"
    in
    div [ class "home-page home-dashboard" ]
        [ section [ class "home-welcome" ]
            [ div [ class "home-welcome-copy" ]
                [ span [ class "eyebrow" ] [ text "Home" ]
                , h1 [] [ text ("Welcome back, " ++ displayName) ]
                , p [] [ text "Pick up a conversation, check your communities, or start something new." ]
                ]
            , div [ class "home-primary-actions" ]
                [ button [ class "btn secondary", onClick NewDmModal ] [ text "New message" ]
                , button [ class "btn", onClick (Go "#new-server") ] [ text "Create server" ]
                ]
            ]
        , div [ class "stat-grid home-stat-grid" ]
            [ statCard "Servers" (String.fromInt (List.length model.servers)) "communities" (Go "#")
            , statCard "Unread messages" (String.fromInt unreadDms) "direct messages" (Go "#dms")
            , statCard "Notifications" (String.fromInt unreadNotifs) "new activity" (Go "#notifications")
            ]
        , div [ class "home-columns" ]
            [ section [ class "card pad home-panel" ]
                [ div [ class "section-head" ]
                    [ div []
                        [ h2 [] [ text "Recent messages" ]
                        , p [ class "muted" ] [ text "Your latest direct conversations." ]
                        ]
                    , button [ class "btn ghost", onClick (Go "#dms") ] [ text "View all" ]
                    ]
                , div [ class "home-recent-list" ]
                    (if List.isEmpty recentConvs then
                        [ div [ class "empty home-empty" ] [ text "No direct messages yet. Start one when you are ready." ] ]
                     else
                        List.map (\c -> convRow c model) recentConvs)
                ]
            , section [ class "card pad home-panel home-activity" ]
                [ div [ class "section-head" ]
                    [ div []
                        [ h2 [] [ text "Recent activity" ]
                        , p [ class "muted" ] [ text "Mentions, replies, and requests that need your attention." ]
                        ]
                    , button [ class "btn ghost", onClick (Go "#notifications") ] [ text "View all" ]
                    ]
                , div [ class "home-activity-list" ]
                    (if List.isEmpty model.notifs then
                        [ div [ class "empty home-empty" ] [ text "Nothing new right now." ] ]
                     else
                        List.map (homeNotificationView model.serverTime) (List.take 5 model.notifs))
                , div [ class "home-quick-links" ]
                    [ button [ class "btn secondary", onClick (Go "#forums") ] [ text "Browse forums" ]
                    , button [ class "btn secondary", onClick (Go "#friends") ] [ text "Friends" ]
                    ]
                ]
            ]
        ]

homeNotificationView : Int -> Notification -> Html Msg
homeNotificationView now notification =
    button
        [ class ("home-activity-row" ++ if notification.seen then "" else " unseen")
        , onClick (Go notification.url)
        ]
        [ span [ class "home-activity-mark", attribute "aria-hidden" "true" ] []
        , span [ class "home-activity-copy" ]
            [ b [] [ text notification.body ]
            , small [ class "muted" ] [ text (notification.kind ++ " · " ++ relativeTime now notification.createdAt) ]
            ]
        ]


statCard : String -> String -> String -> Msg -> Html Msg
statCard label value sub msg =
    button [ class "stat-card", onClick msg ]
        [ span [ class "stat-value" ] [ text value ]
        , b [] [ text label ]
        , small [] [ text sub ]
        ]

renderForumsPage : Model -> Html Msg
renderForumsPage model =
    let
        filtered =
            if String.isEmpty (String.trim model.searchQuery) then
                model.forums
            else
                let q = String.toLower (String.trim model.searchQuery)
                in List.filter (\f ->
                    String.contains q (String.toLower f.name)
                    || String.contains q (String.toLower f.description)
                ) model.forums
        myForums = List.filter .joined filtered
        otherForums = List.filter (\f -> not f.joined) filtered
    in div [ class "forum-page" ]
        [ div [ class "forum-header-bar forum-directory-hero" ]
            [ div [ class "forum-header-title" ]
                [ span [ class "eyebrow" ] [ text "Plainwire Forums" ]
                , h2 [] [ text "Find your community" ]
                , p [ class "muted" ] [ text (String.fromInt (List.length model.forums) ++ " communities for questions, ideas, and conversation") ]
                ]
            , div [ class "forum-header-actions" ]
                [ button [ class "btn", onClick NewForumModal ] [ text "Create Community" ]
                ]
            ]
        , div [ class "forum-search" ]
            [ input
                [ class "forum-search-input"
                , value model.searchQuery
                , placeholder "Search communities..."
                , onInput SearchQuery
                , on "keydown" (D.andThen (\k ->
                    if k == "Enter" then D.succeed DoSearch else D.fail "no")
                    (D.field "key" D.string))
                ] []
            , span [ class "forum-search-icon", attribute "aria-hidden" "true" ] [ span [ class "ui-icon ui-icon-search" ] [] ]
            ]
        , if List.isEmpty filtered then
            div [ class "empty" ] [ text (if String.isEmpty model.searchQuery then "No communities yet." else "No communities match your search.") ]
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
        memberText = String.fromInt f.memberCount ++ " member" ++ (if f.memberCount /= 1 then "s" else "")
        threadText = String.fromInt f.threadCount ++ " thread" ++ (if f.threadCount /= 1 then "s" else "")
    in
    div [ class "forum-card" ]
        [ div [ class "forum-card-top", onClick (Go ("#forum/" ++ String.fromInt f.id)) ]
            [ span [ class "forum-card-icon" ] [ text (String.left 1 (String.toUpper f.name)) ]
            , div [ class "forum-card-info" ]
                [ span [ class "forum-card-kicker" ] [ text ("r/" ++ f.slug) ]
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
            , a [ class "forum-card-link", href ("#forum/" ++ String.fromInt f.id) ] [ text "View →" ]
            ]
        ]

renderForumPage : Int -> Model -> Html Msg
renderForumPage id model =
    let
        forum = List.filter (\f -> f.id == id) model.forums |> List.head
    in
    div [ class "forum-page" ]
        [ case forum of
            Just f ->
                div [ class "forum-view-header" ]
                    [ div [ class "forum-view-title" ]
                        [ span [ class "forum-card-icon large" ] [ text (String.left 1 (String.toUpper f.name)) ]
                        , div []
                            [ span [ class "forum-card-kicker" ] [ text ("r/" ++ f.slug) ]
                            , h2 [] [ text f.name ]
                            , p [ class "muted" ] [ text f.description ]
                            , div [ class "forum-view-stats" ]
                                [ span [ class "forum-stat" ] [ text (String.fromInt f.memberCount ++ " members") ]
                                , span [ class "forum-stat" ] [ text (String.fromInt f.threadCount ++ " threads") ]
                                ]
                            ]
                        ]
                    , div [ class "forum-view-actions" ]
                        [ if f.joined then
                            button [ class "btn forum-joined-btn", onClick (LeaveForum f.id) ] [ text "Joined" ]
                          else
                            button [ class "btn forum-join-btn", onClick (JoinForum f.id) ] [ text "Join" ]
                        , button [ class "btn", onClick (NewThreadModal (Just id)) ] [ text "New Thread" ]
                        , if f.ownerId == Maybe.map .id model.me then
                            button [ class "btn danger", onClick (BridgeEvent "delete_forum" (E.int f.id)) ] [ text "Delete Community" ]
                          else text ""
                        ]
                    ]
            Nothing ->
                div [ class "forum-view-header" ]
                    [ h2 [] [ text "Community" ] ]
        , div [ class "thread-listing" ]
            (List.map (threadRow model) model.threads
                |> (\l -> if List.isEmpty l then [ div [ class "empty" ] [ text "No threads yet. Be the first to post!" ] ] else l)
            )
        ]

threadRow : Model -> ForumThread -> Html Msg
threadRow model t =
    div [ class "reddit-thread", onClick (Go ("#thread/" ++ String.fromInt t.id)) ]
        [ voteColumn t
        , div [ class "thread-content" ]
            [ h3 [ class "thread-title" ]
                ((if t.pinned then [ span [ class "pill pin" ] [ text "pinned" ], text " " ] else [])
                 ++ (if t.score >= 5 || t.replyCount > 10 then [ span [ class "pill hot" ] [ text "hot" ], text " " ] else [])
                 ++ [ text t.title ])
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
            let forumOwner = model.forums
                    |> List.filter (\forum -> forum.id == t.forumId)
                    |> List.head
                    |> Maybe.andThen .ownerId
                myId = Maybe.map .id model.me
                canDelete = myId == Just t.userId || myId == forumOwner
            in div [ class "thread-page" ]
                [ div [ class "thread-breadcrumb" ]
                    [ a [ href ("#forum/" ++ String.fromInt t.forumId) ] [ text ("r/" ++ t.forumName) ]
                    , span [] [ text "›" ]
                    , span [] [ text "Discussion" ]
                    ]
                , div [ class "post card reddit-post" ]
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
                        , div [ class "thread-post-body" ] (renderMessageBody t.body)
                        , div [ class "thread-post-footer" ]
                            [ span [] [ text (String.fromInt t.score ++ " points") ]
                            , span [] [ text (String.fromInt t.views ++ " views") ]
                            , span [] [ text (String.fromInt t.replyCount ++ " replies") ]
                            , if canDelete then
                                button [ class "thread-delete-btn", onClick (BridgeEvent "delete_thread" (E.object [ ("id", E.int t.id), ("forum_id", E.int t.forumId) ])) ] [ text "Delete thread" ]
                              else text ""
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
                        List.indexedMap (replyView model) model.replies)
                , if t.locked then
                    div [ class "locked-banner" ] [ text "This thread is locked. New replies are disabled." ]
                  else
                    composerView ("thread:" ++ String.fromInt threadId) "Reply to thread" model
                ]
        Nothing -> div [ class "empty" ] [ text "Loading thread..." ]

voteColumn : ForumThread -> Html Msg
voteColumn t =
    let
        upValue = if t.userVote == 1 then 0 else 1
        downValue = if t.userVote == -1 then 0 else -1
    in
    div [ class "vote-column" ]
        [ button [ class ("vote-btn up" ++ if t.userVote == 1 then " active" else ""), title "Upvote", onClickStop (VoteThread t.id upValue) ] [ text "▲" ]
        , span [ class "vote-count" ] [ text (String.fromInt t.score) ]
        , button [ class ("vote-btn down" ++ if t.userVote == -1 then " active" else ""), title "Downvote", onClickStop (VoteThread t.id downValue) ] [ text "▼" ]
        ]

replyView : Model -> Int -> Reply -> Html Msg
replyView model idx r =
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
            , div [ class "reply-body" ] (renderMessageBody r.body)
            ]
        ]

renderDmsPage : Model -> Html Msg
renderDmsPage model =
    let
        requests = List.filter (\c -> c.requestState == "pending") model.convs
        conversations = List.filter (\c -> c.requestState /= "pending") model.convs
        unread = List.sum (List.map .unread conversations)
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
            , small [ class "muted dm-preview" ] [ text (Maybe.withDefault "Wants to message you" conversation.lastBody) ]
            ]
        , div [ class "request-actions" ]
            [ button [ class "btn", onClick (BridgeEvent "accept_message_request" (E.int conversation.id)) ] [ text "Accept" ]
            , button [ class "btn secondary", onClick (BridgeEvent "deny_message_request" (E.int conversation.id)) ] [ text "Delete" ]
            ]
        ]

renderFriendsPage : Model -> Html Msg
renderFriendsPage model =
    let
        incoming = List.filter .incoming model.friends
        outgoing = List.filter .outgoing model.friends
        accepted = List.filter (\f -> f.status == "accepted") model.friends
        blocked = List.filter (\f -> f.status == "blocked") model.friends
        online = List.filter (\f -> Dict.get (String.fromInt f.user.id) model.userStatuses /= Nothing) accepted
        pendingCount = List.length incoming + List.length outgoing
        visible = if model.friendsTab == "online" then online else accepted
        listTitle = if model.friendsTab == "online" then "Online" else "All friends"
    in div [ class "friends-page" ]
        [ div [ class "friends-toolbar" ]
            [ h2 [] [ text "Friends" ]
            , nav [ class "friends-tabs", attribute "aria-label" "Friends sections" ]
                [ friendTab model.friendsTab "online" "Online" 0
                , friendTab model.friendsTab "all" "All" 0
                , friendTab model.friendsTab "pending" "Pending" pendingCount
                , friendTab model.friendsTab "blocked" "Blocked" 0
                , friendTab model.friendsTab "add" "Add Friend" 0
                ]
            ]
        , div [ class "friends-content" ]
            [ if model.friendsTab == "pending" then
                div []
                    [ friendSection "Incoming" incoming model.userStatuses
                    , friendSection "Outgoing" outgoing model.userStatuses
                    , if pendingCount == 0 then friendEmpty "You're all caught up" "Incoming and outgoing requests will appear here." else text ""
                    ]
              else if model.friendsTab == "blocked" then
                friendList "Blocked" "Blocked people can't message you or send friend requests." blocked model.userStatuses
              else if model.friendsTab == "add" then
                addFriendPanel model
              else
                friendList listTitle (if model.friendsTab == "online" then "Friends who are online right now." else "Everyone you've added as a friend.") visible model.userStatuses
            ]
        ]

friendTab : String -> String -> String -> Int -> Html Msg
friendTab active key label count =
    button
        [ class ("friends-tab" ++ if active == key then " active" else "")
        , onClick (SetFriendsTab key)
        , attribute "aria-pressed" (if active == key then "true" else "false")
        ]
        [ text label
        , if count > 0 then span [ class "tab-count" ] [ text (String.fromInt count) ] else text ""
        ]

friendList : String -> String -> List Friend -> Dict String String -> Html Msg
friendList heading description friends statuses =
    div []
        [ div [ class "friend-list-head" ]
            [ div [] [ h3 [] [ text (heading ++ "  -  " ++ String.fromInt (List.length friends)) ], p [ class "muted" ] [ text description ] ] ]
        , div [ class "card friends-list" ]
            (if List.isEmpty friends then
                [ friendEmpty (if heading == "Online" then "It's quiet for now" else "Nothing here yet") (if heading == "Online" then "Offline friends will still be waiting in All." else description) ]
             else List.map (friendRow statuses) friends)
        ]

friendEmpty : String -> String -> Html Msg
friendEmpty title body =
    div [ class "empty friend-empty" ] [ b [] [ text title ], p [ class "muted" ] [ text body ] ]

addFriendPanel : Model -> Html Msg
addFriendPanel model =
    let candidates = model.searchUsers
            |> List.filter (\user -> Just user.id /= Maybe.map .id model.me)
    in div [ class "add-friend-panel" ]
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
    let relationship = List.filter (\f -> f.user.id == user.id) model.friends |> List.head
    in div [ class "row friend-row" ]
        [ div [ class "clickable-user", onClick (ShowUserPopup user.id), onContextMenu (OpenUserCtx user) ] [ presenceAvatar model.userStatuses user.id user.avatarUrl user.displayName "" ]
        , div [ class "grow clickable-user", onClick (ShowUserPopup user.id) ]
            [ b [] [ text user.displayName ], small [ class "muted" ] [ text ("@" ++ user.username) ] ]
        , case relationship of
            Just f -> span [ class "relationship-label" ] [ text (if f.status == "accepted" then "Already friends" else if f.outgoing then "Request sent" else if f.incoming then "Request received" else "Blocked") ]
            Nothing -> button [ class "btn", onClick (BridgeEvent "friend_user" (E.int user.id)) ] [ text "Send Friend Request" ]
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
    let statusText = if f.status == "accepted" then statusLabel userStatuses f.user.id else if f.incoming then "Incoming friend request" else if f.outgoing then "Outgoing friend request" else "Blocked"
    in div [ class "row friend-row" ]
        [ div [ class "clickable-user", onClick (ShowUserPopup f.user.id), onContextMenu (OpenUserCtx f.user) ]
            [ presenceAvatar userStatuses f.user.id f.user.avatarUrl f.user.displayName "" ]
        , div [ class "grow clickable-user", onClick (ShowUserPopup f.user.id) ]
            [ b [] [ text f.user.displayName ]
            , small [ class "muted" ] [ text ("@" ++ f.user.username ++ " · " ++ statusText) ]
            ]
        , div [ class "friend-actions" ]
            [ if f.incoming then button [ class "btn", onClick (BridgeEvent "accept_friend" (E.int f.user.id)) ] [ text "Accept" ] else text ""
            , if f.incoming then button [ class "btn secondary", onClick (BridgeEvent "remove_friend" (E.int f.user.id)) ] [ text "Decline" ] else text ""
            , if f.outgoing then button [ class "btn secondary", onClick (BridgeEvent "remove_friend" (E.int f.user.id)) ] [ text "Cancel" ] else text ""
            , if f.status == "accepted" then button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int f.user.id)) ] [ text "Call" ] else text ""
            , if f.status == "accepted" then button [ class "btn secondary", onClick (BridgeEvent "dm_user" (E.int f.user.id)) ] [ text "Message" ] else text ""
            , if f.status == "blocked" then button [ class "btn secondary", onClick (BridgeEvent "remove_friend" (E.int f.user.id)) ] [ text "Unblock" ] else text ""
            ]
        ]

statusLabel : Dict String String -> Int -> String
statusLabel statuses userId =
    case Dict.get (String.fromInt userId) statuses of
        Just "busy" -> "Do Not Disturb"
        Just "away" -> "Idle"
        Just _ -> "Online"
        Nothing -> "Offline"

renderServerPage : Model -> Html Msg
renderServerPage model =
    case model.currentServer of
        Just data ->
            let
                canManage = data.server.role == "owner" || data.server.role == "admin"
                textChannels = List.filter (\c -> c.kind /= "voice") data.channels
                voiceChannels = List.filter (\c -> c.kind == "voice") data.channels
                bannerClass = if String.isEmpty data.server.bannerUrl then "server-hero" else "server-hero has-banner"
            in
            div [ class "server-page page-stack" ]
                [ section
                    [ class ("card " ++ bannerClass)
                    , style "--server-accent" data.server.accentColor
                    , style "background-image"
                        (if String.isEmpty data.server.bannerUrl then
                            "none"
                         else
                            "url('" ++ data.server.bannerUrl ++ "')"
                        )
                    ]
                    [ div [ class "server-hero-main" ]
                        [ serverIcon data.server
                        , div [ class "server-hero-copy" ]
                            [ span [ class "eyebrow" ] [ text "Server" ]
                            , h1 [] [ text data.server.name ]
                            , p [] [ text (if String.isEmpty data.server.description then "A Plainwire community." else data.server.description) ]
                            ]
                        ]
                    , div [ class "server-meta" ]
                        [ span [ class "server-meta-item" ] [ b [] [ text (String.fromInt (List.length data.members)) ], text " members" ]
                        , span [ class "server-meta-item" ] [ b [] [ text (String.fromInt (List.length textChannels)) ], text " text" ]
                        , span [ class "server-meta-item" ] [ b [] [ text (String.fromInt (List.length voiceChannels)) ], text " voice" ]
                        , span [ class "server-role-badge" ] [ text data.server.role ]
                        ]
                    , if canManage then
                        div [ class "server-hero-actions" ]
                            [ button [ class "btn", onClick (InviteModal data.server.id) ] [ text "Invite people" ]
                            , button [ class "btn secondary", onClick (ChannelModal data.server.id) ] [ text "Add channel" ]
                            , button [ class "btn secondary", onClick (EditServerModal data.server) ] [ text "Customize" ]
                            ]
                      else
                        text ""
                    ]
                , div [ class "server-overview-grid" ]
                    [ section [ class "card server-overview-panel server-channel-panel" ]
                        [ div [ class "section-head compact-section-head" ]
                            [ div []
                                [ h2 [] [ text "Channels" ]
                                , p [ class "muted" ] [ text "Jump into text or voice." ]
                                ]
                            , if canManage then button [ class "btn ghost", onClick (ChannelModal data.server.id) ] [ text "Add" ] else text ""
                            ]
                        , div [ class "server-channel-card" ]
                            (channelGroup "Text channels" textChannels
                             ++ channelGroup "Voice channels" voiceChannels)
                        ]
                    , section [ class "card server-overview-panel server-member-panel" ]
                        [ div [ class "section-head compact-section-head" ]
                            [ div []
                                [ h2 [] [ text "Members" ]
                                , p [ class "muted" ] [ text (String.fromInt (List.length data.members) ++ " people in this server") ]
                                ]
                            ]
                        , div [ class "server-member-list" ] (List.map (\m -> memberRow model.userStatuses m) data.members)
                        ]
                    ]
                ]
        Nothing ->
            div [ class "page-loading" ] [ span [ class "loading-dot" ] [], text "Loading server" ]

channelRow : Channel -> Html Msg
channelRow c =
    let target = if c.kind == "voice" then "#voice/" else "#channel/"
    in a [ class "row channel-link", href (target ++ String.fromInt c.id), onClick (Go (target ++ String.fromInt c.id)) ]
        [ span [ class ("channel-glyph " ++ if c.kind == "voice" then "voice" else "text"), attribute "aria-hidden" "true" ] []
        , div [ class "grow" ] [ b [] [ text c.name ], small [ class "muted" ] [ text (if c.kind == "voice" then "Voice channel" else "Text channel") ] ]
        ]


managedChannelRow : Bool -> List Category -> Channel -> Html Msg
managedChannelRow canManage categories channel =
    let
        target = if channel.kind == "voice" then "#voice/" else "#channel/"
        selectedCategory = Maybe.map String.fromInt channel.categoryId |> Maybe.withDefault ""
        moveTarget raw = MoveChannelToCategory channel.id (if String.isEmpty raw then Nothing else String.toInt raw)
        categoryOptions =
            option [ value "" ] [ text "No category" ]
                :: List.map (\category -> option [ value (String.fromInt category.id) ] [ text category.name ]) categories
    in
    div [ class "row", onClick (Go (target ++ String.fromInt channel.id)) ]
        [ span [ class ("channel-glyph " ++ if channel.kind == "voice" then "voice" else "text"), attribute "aria-hidden" "true" ] []
        , div [ class "grow" ] [ b [] [ text channel.name ], small [ class "muted" ] [ text (if channel.kind == "voice" then "Voice channel" else "Text channel") ] ]
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

memberRow : Dict String String -> ServerMember -> Html Msg
memberRow userStatuses m =
    div [ class "row member-row clickable-user", onClick (ShowUserPopup m.user.id), onContextMenu (OpenUserCtx m.user) ]
        [ presenceAvatar userStatuses m.user.id m.user.avatarUrl m.user.displayName ""
        , div [ class "grow" ]
            [ b [] [ text m.user.displayName ]
            , small [ class "muted" ] [ text ("@" ++ m.user.username ++ " · " ++ m.role) ]
            ]
        ]

renderVoicePage : Int -> Model -> Html Msg
renderVoicePage channelId model =
    let joined = model.voice.mode == Just "voice" && model.voice.id == Just channelId
        members = Maybe.map .members model.currentServer |> Maybe.withDefault []
        voiceUsers = Dict.values model.voice.users
        hasScreenShare = List.any .screen voiceUsers
        shareCount = List.length (List.filter .screen voiceUsers)
        participantCount = List.length voiceUsers
    in
    div []
        [ div [ class "card pad voice-card" ]
            [ div [ class "voice-header" ]
                [ h2 [] [ text "Voice channel" ]
                , if joined then
                    span [ class "voice-count" ] [ text (String.fromInt participantCount ++ " in call") ]
                  else text ""
                ]
            , p [ class "muted" ] [ text "Join when you want to talk. Use Enable audio if your phone or browser blocks playback." ]
            , div [ class "voice-actions" ]
                [ if joined then
                    button [ class "btn call-decline", onClick EndCall ] [ text "Leave" ]
                  else
                    button [ class "btn primary-join", onClick (BridgeEvent "join_voice" (E.int channelId)) ] [ text "Join" ]
                , button [ class ("btn" ++ if model.voice.muted then " call-muted" else " secondary"), onClick (BridgeEvent "toggle_mute" E.null) ] [ text (if model.voice.muted then "Unmute" else "Mute") ]
                , button [ class ("btn" ++ if model.voice.deafened then " call-muted" else " secondary"), onClick (BridgeEvent "toggle_deafen" E.null) ] [ text (if model.voice.deafened then "Undeafen" else "Deafen") ]
                , button [ class "btn secondary", onClick (BridgeEvent "unlock_audio" E.null) ] [ text "Enable audio" ]
                , if joined then
                    if model.voice.screenShare then
                        button [ class "btn call-decline share-active", onClick StopScreenShare ] [ text "Stop share" ]
                    else
                        button [ class "btn share-btn", onClick StartScreenShare ] [ text "Share screen" ]
                  else text ""
                ]
            , if hasScreenShare then
                div [ class "voice-screen-banner" ]
                    [ span [ class "screen-pulse" ] []
                    , text (String.fromInt shareCount ++ " sharing screen  -  look for the floating window")
                    ]
              else text ""
            , div [ class "voice-participants" ]
                (if not joined || List.isEmpty voiceUsers then
                    [ div [ class "empty voice-empty" ]
                        [ text (if joined then "Waiting for others to join..." else "Join to see voice participants.") ]
                 ]
                 else
                    List.map (voiceParticipantRow members) voiceUsers)
            ]
        ]

voiceParticipantRow : List ServerMember -> { userId : Int, muted : Bool, deafened : Bool, screen : Bool, reconnecting : Bool } -> Html Msg
voiceParticipantRow members vu =
    let maybeMember = List.filter (\m -> m.user.id == vu.userId) members |> List.head
        name = maybeMember |> Maybe.map (\m -> m.user.displayName) |> Maybe.withDefault ("User " ++ String.fromInt vu.userId)
        avatarUrl = maybeMember |> Maybe.map (\m -> m.user.avatarUrl) |> Maybe.withDefault ""
        stateText =
            if vu.reconnecting then "Reconnecting"
            else if vu.screen then "Sharing screen"
            else if vu.deafened then "Deafened"
            else if vu.muted then "Muted"
            else "Live"
        pillClass =
            if vu.reconnecting then "voice-state-pill reconnecting"
            else if vu.screen then "voice-state-pill sharing"
            else if vu.muted || vu.deafened then "voice-state-pill muted"
            else "voice-state-pill live"
        pillText =
            if vu.reconnecting then "Rejoining"
            else if vu.screen then "Sharing"
            else if vu.deafened then "Deafened"
            else if vu.muted then "Muted"
            else "Live"
    in
    div [ class ("row voice-participant" ++ if vu.screen then " screen-sharing" else "") ]
        [ avatarImg avatarUrl name "small"
        , div [ class "grow" ]
            [ b [] [ text name ]
            , small [ class "muted" ] [ text stateText ]
            ]
        , span [ class pillClass ] [ text pillText ]
        ]

renderProfilePage : Model -> Html Msg
renderProfilePage model =
    case model.currentProfile of
        Just u ->
            let
                viewingSelf = Maybe.map .id model.me == Just u.id
                liveStatus = Dict.get (String.fromInt u.id) model.userStatuses
                presence = Maybe.withDefault "offline" liveStatus
                activityText =
                    case liveStatus of
                        Just "away" -> "Away"
                        Just "busy" -> "Do not disturb"
                        Just "invisible" -> "Offline"
                        Just _ -> "Online"
                        Nothing ->
                            let elapsed = agoAt model.serverTime u.lastSeen
                            in if elapsed == "never" then "Offline"
                               else if elapsed == "now" || elapsed == "1s" then "Last seen just now"
                               else "Last seen " ++ elapsed ++ " ago"
            in
            article [ class "card profile profile-page-card" ]
                [ div
                    [ class ("banner profile-cover" ++ if String.isEmpty u.bannerUrl then " empty" else "")
                    , style "background-image" (if String.isEmpty u.bannerUrl then "none" else "url('" ++ u.bannerUrl ++ "')")
                    ] []
                , div [ class "profile-body profile-layout" ]
                    [ div [ class "profile-avatar-column" ]
                        [ presenceAvatar model.userStatuses u.id u.avatarUrl u.displayName "big" ]
                    , div [ class "profile-copy" ]
                        [ div [ class "profile-title-row" ]
                            [ div []
                                [ h1 [] [ text u.displayName ]
                                , p [ class "muted profile-identity" ] [ text ("@" ++ u.username) ]
                                ]
                            , span [ class ("presence-pill profile-presence " ++ presence) ]
                                [ span [ class ("status-dot " ++ presence) ] [], text activityText ]
                            ]
                        , div [ class "profile-bio" ]
                            [ span [ class "profile-section-label" ] [ text "About" ]
                            , p [] [ text (if String.isEmpty (String.trim u.bio) then "No bio set yet." else u.bio) ]
                            ]
                        , div [ class "profile-actions" ]
                            [ if viewingSelf then button [ class "btn", onClick (Go "#settings") ] [ text "Edit profile" ] else text ""
                            , if not viewingSelf && model.currentProfileRelationship /= "blocked" then button [ class "btn", onClick (BridgeEvent "dm_user" (E.int u.id)) ] [ text "Message" ] else text ""
                            , if not viewingSelf && model.currentProfileRelationship /= "blocked" then button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int u.id)) ] [ text "Call" ] else text ""
                            , if not viewingSelf && model.currentProfileRelationship == "blocked" && model.currentProfileBlockedByMe then
                                button [ class "btn danger", onClick (BridgeEvent "unblock_user" (E.int u.id)) ] [ text "Unblock" ]
                              else if not viewingSelf && model.currentProfileRelationship == "blocked" then
                                button [ class "btn secondary", disabled True ] [ text "Unavailable" ]
                              else if not viewingSelf then
                                button [ class "btn ghost profile-more-action", onClick (BridgeEvent "block_user" (E.int u.id)) ] [ text "Block" ]
                              else text ""
                            ]
                        ]
                    ]
                ]
        Nothing ->
            div [ class "page-loading" ] [ span [ class "loading-dot" ] [], text "Loading profile" ]

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
                    ]
                , aside [ class "settings-sidebar" ]
                    [ div [ class "settings-nav-label" ] [ text "User settings" ]
                    , button [ type_ "button", class ("settings-tab" ++ if model.settingsTab == "profile" then " active" else ""), onClick (SetSettingsTab "profile") ] [ text "Profile" ]
                    , button [ type_ "button", class ("settings-tab" ++ if model.settingsTab == "appearance" then " active" else ""), onClick (SetSettingsTab "appearance") ] [ text "Appearance" ]
                    , button [ type_ "button", class ("settings-tab" ++ if model.settingsTab == "chat" then " active" else ""), onClick (SetSettingsTab "chat") ] [ text "Chat" ]
                    , button [ type_ "button", class ("settings-tab" ++ if model.settingsTab == "voice" then " active" else ""), onClick (SetSettingsTab "voice") ] [ text "Voice & Video" ]
                    , button [ type_ "button", class ("settings-tab" ++ if model.settingsTab == "sound" then " active" else ""), onClick (SetSettingsTab "sound") ] [ text "Notifications" ]
                    , button [ type_ "button", class ("settings-tab" ++ if model.settingsTab == "privacy" then " active" else ""), onClick (SetSettingsTab "privacy") ] [ text "Privacy & Safety" ]
                    , div [ class "settings-nav-separator" ] []
                    , button [ type_ "button", class ("settings-tab" ++ if model.settingsTab == "account" then " active" else ""), onClick (SetSettingsTab "account") ] [ text "Account" ]
                    ]
                , div [ class "settings-content" ]
                    [ div [ class "settings-content-top" ]
                        [ div [] [ span [ class "eyebrow" ] [ text "Personal settings" ], h1 [] [ text (settingsTitle model.settingsTab) ] ]
                        , span [ class "settings-user-chip" ] [ avatarImg u.avatarUrl u.displayName "small", text ("@" ++ u.username) ]
                        ]
                    , div [ class "settings-content-inner" ]
                        [ case model.settingsTab of
                            "appearance" -> renderAppearanceSettings model
                            "chat" -> renderChatSettings model
                            "voice" -> renderVoiceSettings model
                            "sound" -> renderNotificationSettings model
                            "privacy" -> renderPrivacySettings model
                            "account" -> renderAccountSettings u model
                            _ -> renderProfileSettings u model
                        ]
                    ]
                ]
        Nothing -> text ""

settingsMobileTab : String -> String -> String -> Html Msg
settingsMobileTab current key label =
    button
        [ type_ "button"
        , class ("settings-mobile-tab" ++ if current == key then " active" else "")
        , onClick (SetSettingsTab key)
        , attribute "aria-current" (if current == key then "page" else "false")
        ]
        [ text label ]


settingsTitle : String -> String
settingsTitle tab =
    case tab of
        "appearance" -> "Appearance"
        "chat" -> "Chat"
        "voice" -> "Voice & Video"
        "sound" -> "Notifications"
        "privacy" -> "Privacy & Safety"
        "account" -> "Account"
        _ -> "My Profile"

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
        , div [ class "account-action-grid" ]
            [ button [ class "settings-action-card", onClick (BridgeEvent "account_change_password" E.null) ]
                [ b [] [ text "Change password" ], small [ class "muted" ] [ text "Update your password and sign out other sessions." ] ]
            , button [ class "settings-action-card", onClick (BridgeEvent "account_sessions" E.null) ]
                [ b [] [ text "Active sessions" ], small [ class "muted" ] [ text "Review where your account is currently signed in." ] ]
            , button [ class "settings-action-card", onClick (BridgeEvent "account_diagnostics" E.null) ]
                [ b [] [ text "Connection diagnostics" ], small [ class "muted" ] [ text "Check WebSocket, database, browser, and TURN readiness." ] ]
            ]
        , div [ class "setting-row settings-about-row" ]
            [ div [] [ b [] [ text "Plainwire" ], small [ class "muted" ] [ text ("Version " ++ model.clientVersion) ] ]
            , span [ class "pill" ] [ text "Web client" ]
            ]
        , div [ class "danger-zone" ]
            [ div []
                [ b [] [ text "Log out" ]
                , p [ class "muted" ] [ text "End this browser session." ]
                ]
            , button [ class "btn danger", onClick Logout ] [ text "Log out" ]
            ]
        ]

renderChatSettings : Model -> Html Msg
renderChatSettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Chat" ], p [ class "muted" ] [ text "Tune message composition and media behavior on this device." ] ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Send message with Enter" ], small [ class "muted" ] [ text "Choose whether Enter sends or adds a new line." ] ]
            , div [ class "segmented-control" ]
                [ button [ class ("btn secondary" ++ if model.chatEnterSends then " active-choice" else ""), onClick (SetChatEnterSends True) ] [ text "Enter sends" ]
                , button [ class ("btn secondary" ++ if not model.chatEnterSends then " active-choice" else ""), onClick (SetChatEnterSends False) ] [ text "Ctrl/Cmd + Enter sends" ]
                ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Link previews" ], small [ class "muted" ] [ text "Show rich cards for supported links." ] ] ]
            , button [ class ("settings-switch" ++ if model.linkPreviewsEnabled then " active" else ""), onClick (SetLinkPreviewsEnabled (not model.linkPreviewsEnabled)), attribute "role" "switch", attribute "aria-checked" (if model.linkPreviewsEnabled then "true" else "false"), title "Toggle link previews" ] [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Autoplay animated media" ], small [ class "muted" ] [ text "Control GIF and animated image playback." ] ] ]
            , button [ class ("settings-switch" ++ if model.animatedMediaEnabled then " active" else ""), onClick (SetAnimatedMediaEnabled (not model.animatedMediaEnabled)), attribute "role" "switch", attribute "aria-checked" (if model.animatedMediaEnabled then "true" else "false"), title "Toggle animated media" ] [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Compact message spacing" ], small [ class "muted" ] [ text "Reduce vertical spacing between grouped messages." ] ] ]
            , button [ class ("settings-switch" ++ if model.compactMessages then " active" else ""), onClick (SetCompactMessages (not model.compactMessages)), attribute "role" "switch", attribute "aria-checked" (if model.compactMessages then "true" else "false"), title "Toggle compact message spacing" ] [ span [ class "settings-switch-knob" ] [] ]
            ]
        ]

renderPrivacySettings : Model -> Html Msg
renderPrivacySettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Privacy & Safety" ], p [ class "muted" ] [ text "Control browser-side privacy behavior and review account security." ] ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Media preloading" ], small [ class "muted" ] [ text "Preload remote images for smoother scrolling." ] ] ]
            , button [ class ("settings-switch" ++ if model.mediaPreloadEnabled then " active" else ""), onClick (SetMediaPreloadEnabled (not model.mediaPreloadEnabled)), attribute "role" "switch", attribute "aria-checked" (if model.mediaPreloadEnabled then "true" else "false"), title "Toggle media preloading" ] [ span [ class "settings-switch-knob" ] [] ]
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
                [ button [ class ("btn secondary" ++ if model.uiDensity == "comfortable" then " active-choice" else ""), onClick (BridgeEvent "ui_density" (E.string "comfortable")) ] [ text "Comfortable" ]
                , button [ class ("btn secondary" ++ if model.uiDensity == "compact" then " active-choice" else ""), onClick (BridgeEvent "ui_density" (E.string "compact")) ] [ text "Compact" ]
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Text size" ], small [ class "muted" ] [ text "Scale the interface without changing your browser zoom." ] ]
            , div [ class "segmented-control" ]
                [ button [ class ("btn secondary" ++ if model.uiFontScale == "small" then " active-choice" else ""), onClick (BridgeEvent "ui_font_scale" (E.string "small")) ] [ text "Small" ]
                , button [ class ("btn secondary" ++ if model.uiFontScale == "default" then " active-choice" else ""), onClick (BridgeEvent "ui_font_scale" (E.string "default")) ] [ text "Default" ]
                , button [ class ("btn secondary" ++ if model.uiFontScale == "large" then " active-choice" else ""), onClick (BridgeEvent "ui_font_scale" (E.string "large")) ] [ text "Large" ]
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Accent" ], small [ class "muted" ] [ text "Choose the main interface color on this device." ] ]
            , div [ class "segmented-control" ]
                [ button [ class ("btn secondary" ++ if model.uiAccent == "blue" then " active-choice" else ""), onClick (BridgeEvent "ui_accent" (E.string "blue")) ] [ text "Blue" ]
                , button [ class ("btn secondary" ++ if model.uiAccent == "teal" then " active-choice" else ""), onClick (BridgeEvent "ui_accent" (E.string "teal")) ] [ text "Teal" ]
                , button [ class ("btn secondary" ++ if model.uiAccent == "green" then " active-choice" else ""), onClick (BridgeEvent "ui_accent" (E.string "green")) ] [ text "Green" ]
                , button [ class ("btn secondary" ++ if model.uiAccent == "amber" then " active-choice" else ""), onClick (BridgeEvent "ui_accent" (E.string "amber")) ] [ text "Amber" ]
                , button [ class ("btn secondary" ++ if model.uiAccent == "rose" then " active-choice" else ""), onClick (BridgeEvent "ui_accent" (E.string "rose")) ] [ text "Rose" ]
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Corners" ], small [ class "muted" ] [ text "Keep the interface tight or give panels a little more rounding." ] ]
            , div [ class "segmented-control" ]
                [ button [ class ("btn secondary" ++ if model.uiCornerStyle == "compact" then " active-choice" else ""), onClick (BridgeEvent "ui_corner_style" (E.string "compact")) ] [ text "Compact" ]
                , button [ class ("btn secondary" ++ if model.uiCornerStyle == "default" then " active-choice" else ""), onClick (BridgeEvent "ui_corner_style" (E.string "default")) ] [ text "Default" ]
                , button [ class ("btn secondary" ++ if model.uiCornerStyle == "rounded" then " active-choice" else ""), onClick (BridgeEvent "ui_corner_style" (E.string "rounded")) ] [ text "Rounded" ]
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Motion" ], small [ class "muted" ] [ text "Reduce interface animation when you prefer less movement." ] ]
            , div [ class "segmented-control" ]
                [ button [ class ("btn secondary" ++ if not model.reduceMotion then " active-choice" else ""), onClick (BridgeEvent "reduce_motion" (E.bool False)) ] [ text "Standard" ]
                , button [ class ("btn secondary" ++ if model.reduceMotion then " active-choice" else ""), onClick (BridgeEvent "reduce_motion" (E.bool True)) ] [ text "Reduced" ]
                ]
            ]
        ]

renderNotificationSettings : Model -> Html Msg
renderNotificationSettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Notifications" ], p [ class "muted" ] [ text "Control alerts on this device." ] ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Sound effects" ], small [ class "muted" ] [ text "Play sounds for messages, calls, and important activity." ] ] ]
            , button
                [ class ("settings-switch" ++ if model.soundEnabled then " active" else "")
                , onClick ToggleSound, attribute "role" "switch", attribute "aria-checked" (if model.soundEnabled then "true" else "false"), title "Toggle sound effects"
                ] [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ div [] [ b [] [ text "Desktop notifications" ], small [ class "muted" ] [ text "Get alerts while Plainwire is open in the background." ] ] ]
            , button [ class "btn secondary settings-action", onClick (BridgeEvent "request_notifications" E.null) ] [ text "Review permission" ]
            ]
        , div [ class "notification-sound-preview" ]
            [ div [] [ b [] [ text "Sound preview" ], small [ class "muted" ] [ text "Short, soft cues designed to stay out of the way." ] ]
            , div [ class "segmented-control" ]
                [ button [ class "btn secondary", onClick (BridgeEvent "preview_sound" (E.string "notification")) ] [ text "Message" ]
                , button [ class "btn secondary", onClick (BridgeEvent "preview_sound" (E.string "incoming")) ] [ text "Incoming call" ]
                ]
            ]
        ]

renderVoiceSettings : Model -> Html Msg
renderVoiceSettings model =
    let
        deviceOptions devices =
            option [ value "" ] [ text "System default" ]
                :: List.map (\device -> option [ value device.id ] [ text device.label ]) devices
        level = String.fromInt (Basics.max 0 (Basics.min 100 model.micTestLevel)) ++ "%"
        processingButton processingMode heading copy enabled =
            button
                [ type_ "button"
                , class ("voice-mode" ++ if model.voiceProcessingMode == processingMode then " active" else "")
                , onClick (SelectVoiceProcessing processingMode)
                , disabled (not enabled)
                , attribute "aria-pressed" (if model.voiceProcessingMode == processingMode then "true" else "false")
                ]
                [ span [ class "voice-mode-title" ] [ text heading ]
                , span [ class "voice-mode-copy" ] [ text copy ]
                ]
    in
    div [ class "settings-card settings-panel voice-settings" ]
        [ div [ class "settings-card-head" ]
            [ h2 [] [ text "Voice & Video" ]
            , p [ class "muted" ] [ text "Choose devices and verify your microphone before joining friends." ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Input device" ], small [ class "muted" ] [ text "The microphone used in calls and voice channels." ] ]
            , select [ value model.selectedAudioInput, onInput SelectAudioInput ] (deviceOptions model.audioInputs)
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Output device" ], small [ class "muted" ] [ text (if model.outputSelectionSupported then "Where call audio plays." else "This browser uses your system output device.") ] ]
            , select [ value model.selectedAudioOutput, onInput SelectAudioOutput, disabled (not model.outputSelectionSupported) ] (deviceOptions model.audioOutputs)
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div []
                [ b [] [ text "Microphone processing" ]
                , small [ class "muted" ] [ text "Pick a lightweight everyday mode or preserve the microphone's natural signal." ]
                ]
            , div [ class "voice-mode-grid", attribute "role" "group", attribute "aria-label" "Microphone processing mode" ]
                [ processingButton "noise" "Noise cancelling" "Browser echo control, noise reduction, and automatic level." True
                , processingButton "studio" "Studio mic" "Unprocessed, full-band input for a quiet room and headphones." True
                , processingButton "krisp" "Krisp AI" (if model.krispAvailable then "Licensed Krisp processing is ready on this server." else "Add the licensed Krisp browser SDK and models to enable.") model.krispAvailable
                ]
            ]
        , div [ class "setting-row setting-row-stack mic-test-card" ]
            [ div [] [ b [] [ text "Mic test" ], small [ class "muted" ] [ text "Speak normally. The meter and playback use the selected processing mode." ] ]
            , div [ class "mic-meter", attribute "role" "meter", attribute "aria-label" "Microphone input level", attribute "aria-valuenow" (String.fromInt model.micTestLevel), attribute "aria-valuemin" "0", attribute "aria-valuemax" "100" ]
                [ span [ class "mic-meter-fill", style "width" level ] []
                , span [ class "mic-meter-peak" ] []
                ]
            , div [ class "mic-test-actions" ]
                [ button [ class ("btn " ++ if model.micTesting then "danger" else "secondary"), onClick ToggleMicTest ]
                    [ text (if model.micTesting then "Stop test" else "Test microphone") ]
                , button
                    [ class ("btn secondary" ++ if model.micMonitoring then " active" else "")
                    , onClick ToggleMicMonitor
                    , disabled (not model.micTesting)
                    , attribute "aria-pressed" (if model.micMonitoring then "true" else "false")
                    , title "Use headphones to avoid feedback"
                    ]
                    [ text (if model.micMonitoring then "Stop playback" else "Hear myself") ]
                , button [ class "btn ghost", onClick (BridgeEvent "list_audio_devices" E.null) ] [ text "Refresh devices" ]
                ]
            , if model.micMonitoring then
                small [ class "mic-monitor-warning" ] [ text "Playback is on. Wear headphones to prevent feedback." ]
              else
                text ""
            ]
        , div [ class "voice-settings-note" ]
            [ b [] [ text "Connection tip" ]
            , p [ class "muted" ] [ text "For calls outside your home network, configure TURN before launch. Plainwire will show each remote peer as connected only after ICE and audio are actually established." ]
            ]
        ]

renderProfileSettings : User -> Model -> Html Msg
renderProfileSettings u model =
    div [ class "settings-card" ]
        [ div [ class "settings-banner", style "background-image" (if String.isEmpty model.profileBannerPreviewUrl then "none" else "url('" ++ model.profileBannerPreviewUrl ++ "')") ]
            [ div [ class "settings-avatar-wrap" ] [ avatarImg model.profileAvatarPreviewUrl model.profileDisplayName "" ]
            , div [ class "settings-name-block" ]
                [ h2 [] [ text (if String.isEmpty model.profileDisplayName then u.displayName else model.profileDisplayName) ]
                , p [ class "muted" ] [ text ("@" ++ u.username) ]
                ]
            ]
        , div [ class "settings-fields" ]
            [ div [ class "field" ]
            [ label [] [ text "Display name" ]
            , input [ value model.profileDisplayName, maxlength 48, onInput ProfileDisplayName ] []
            ]
        , div [ class "field" ]
            [ label [] [ text "Bio" ]
            , textarea [ value model.profileBio, maxlength 600, onInput ProfileBio ] []
            ]
        , div [ class "field" ]
            [ label [] [ text "Avatar URL" ]
            , input [ value model.profileAvatarUrl, placeholder "https://...", onInput ProfileAvatarUrl ] []
            , div [ class "file-picker-row" ]
                [ input [ id "profileAvatarFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "profileAvatarFile")) ] []
                , label [ class ("btn secondary file-picker-button" ++ if model.profileAvatarUploading then " disabled" else ""), attribute "for" "profileAvatarFile", attribute "aria-disabled" (if model.profileAvatarUploading then "true" else "false") ] [ text (if model.profileAvatarUploading then "Uploading..." else "Choose avatar") ]
                , small [ class "muted" ] [ text "JPEG, PNG, GIF, WebP, or AVIF" ]
                ]
            ]
        , div [ class "field" ]
            [ label [] [ text "Banner URL" ]
            , input [ value model.profileBannerUrl, placeholder "https://...", onInput ProfileBannerUrl ] []
            , div [ class "file-picker-row" ]
                [ input [ id "profileBannerFile", class "file-picker-input", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "profileBannerFile")) ] []
                , label [ class ("btn secondary file-picker-button" ++ if model.profileBannerUploading then " disabled" else ""), attribute "for" "profileBannerFile", attribute "aria-disabled" (if model.profileBannerUploading then "true" else "false") ] [ text (if model.profileBannerUploading then "Uploading..." else "Choose banner") ]
                , small [ class "muted" ] [ text "JPEG, PNG, GIF, WebP, or AVIF" ]
                ]
            ]
        , div [ class "field" ]
            [ label [] [ text "Status" ]
            , select [ value model.profileStatus, onInput ProfileStatus ]
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

renderNewServerPage : Model -> Html Msg
renderNewServerPage model =
    div [ class "server-create-page" ]
        [ section [ class "server-create-intro" ]
            [ span [ class "server-create-mark" ] [ text "+" ]
            , span [ class "eyebrow" ] [ text "New space" ]
            , h1 [] [ text "Create a server" ]
            , p [ class "muted" ] [ text "Give your group a home. Plainwire creates sensible text and voice defaults, and you can customize everything afterward." ]
            , div [ class "server-create-preview" ]
                [ div [ class "server-icon" ] [ text (if String.isEmpty (String.trim model.serverName) then "S" else String.left 1 (String.toUpper model.serverName)) ]
                , div []
                    [ b [] [ text (if String.isEmpty (String.trim model.serverName) then "Your server" else String.trim model.serverName) ]
                    , small [ class "muted" ] [ text (if String.isEmpty (String.trim model.serverDescription) then "A place for your friends" else String.trim model.serverDescription) ]
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
                , if invite.valid then button [ class "btn", onClick JoinInvite ] [ text "Accept invite" ] else p [ class "muted" ] [ text "This invite is no longer valid." ]
                , button [ class "btn secondary", onClick (Go "#") ] [ text "Back home" ]
                ]
        Nothing -> div [ class "empty" ] [ text "Loading invite..." ]

renderMessagePage : String -> String -> Model -> Html Msg
renderMessagePage draftKey placeholderText model =
    let callBar = case model.active of
            DmView convId ->
                case callForConversation convId model of
                    Just active -> [ renderDmCallBar active model ]
                    Nothing -> []
            _ -> []
        chatSurface = div [ class "chat-surface" ]
            ( callBar
            ++ [ renderChatHeader model
               , div [ class "messages", id "messages" ]
                    ([ div [ id "message-history-sentinel", class "message-history-sentinel", attribute "aria-hidden" "true" ]
                         [ if model.loadingOlderMessages then text "Loading older messages…" else text "" ]
                     ] ++ if List.isEmpty model.msg then
                        [ div [ class "empty chat-empty" ] [ h2 [] [ text "Start the conversation" ], p [ class "muted" ] [ text "Messages appear here instantly when people post." ] ] ]
                     else
                        groupedMessageViews model model.msg
                    )
               , composerView draftKey placeholderText model
               ]
            )
        groupMembers = case model.active of
            DmView conversationId ->
                model.convs
                    |> List.filter (\conversation -> conversation.id == conversationId && conversation.memberCount > 2)
                    |> List.head
                    |> Maybe.map (\conversation ->
                        let cachedMembers = Dict.get conversationId model.conversationMembers |> Maybe.withDefault conversation.members
                        in renderGroupMembers model { conversation | members = cachedMembers }
                    )
            _ -> Nothing
    in case groupMembers of
        Just members -> div [ class "chat-with-members" ] [ chatSurface, members ]
        Nothing -> chatSurface


renderGroupMembers : Model -> Conversation -> Html Msg
renderGroupMembers model conversation =
    aside [ class "group-members", attribute "aria-label" "Group members" ]
        [ div [ class "group-members-head" ]
            [ span [ class "eyebrow" ] [ text "People" ]
            , h3 [] [ text (String.fromInt conversation.memberCount ++ " members") ]
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
    let user = member.user
    in button [ class "group-member", onClick (ShowUserPopup user.id), onContextMenu (OpenUserCtx user), attribute "aria-label" ("Open " ++ user.displayName ++ "'s profile") ]
        [ div [ class "group-member-avatar" ]
            [ presenceAvatar model.userStatuses user.id user.avatarUrl user.displayName ""
            ]
        , div [ class "group-member-copy" ]
            [ b [] [ text user.displayName ]
            , small [ class "muted" ] [ text ("@" ++ user.username) ]
            ]
        , if user.id == ownerId then span [ class "pill group-owner" ] [ text "owner" ] else text ""
        ]

renderChatHeader : Model -> Html Msg
renderChatHeader model =
    case model.active of
        DmView id ->
            case List.filter (\c -> c.id == id) model.convs of
                c :: _ ->
                    let hasCall = callForConversation id model /= Nothing
                        joinedCall = isJoinedCall id model
                    in div [ class "chat-header" ]
                        [ button [ class "chat-mobile-menu", type_ "button", onClick ToggleSidebar, attribute "aria-label" "Open navigation" ] [ span [ class "ui-icon ui-icon-menu", attribute "aria-hidden" "true" ] [] ]
                        , convAvatar model c
                        , div [ class "grow" ]
                            [ h2 [] [ text (convName c) ]
                            , small [ class "muted" ] [ text (if c.memberCount > 2 then String.fromInt c.memberCount ++ " people" else "Direct message") ]
                            ]
                        , chatConnectionBadge model
                        , if joinedCall then
                            button [ class "btn call-decline chat-call-action", onClick EndCall ] [ span [ class "ui-icon ui-icon-call-end", attribute "aria-hidden" "true" ] [], span [ class "chat-call-label" ] [ text "Leave" ] ]
                          else if hasCall then
                            button [ class "btn call-accept chat-call-action", onClick (JoinCall id) ] [ span [ class "ui-icon ui-icon-call", attribute "aria-hidden" "true" ] [], span [ class "chat-call-label" ] [ text "Join" ] ]
                          else
                            button [ class "btn chat-call-action", onClick (BridgeEvent "start_call" (E.int id)), attribute "aria-label" "Start call" ] [ span [ class "ui-icon ui-icon-call", attribute "aria-hidden" "true" ] [], span [ class "chat-call-label" ] [ text "Call" ] ]
                        ]
                [] -> chatOnlineHeader model
        ChannelView channelId -> channelChatHeader channelId model
        _ -> chatOnlineHeader model

isJoinedCall : Int -> Model -> Bool
isJoinedCall conversationId model =
    model.voice.mode == Just "call" && model.voice.id == Just conversationId

callForConversation : Int -> Model -> Maybe ActiveCall
callForConversation conversationId model =
    if isJoinedCall conversationId model then
        Maybe.andThen
            (\call -> if call.conversationId == conversationId then Just call else Nothing)
            model.callUI.active
    else
        Dict.get conversationId model.activeCalls

renderDmCallBar : ActiveCall -> Model -> Html Msg
renderDmCallBar active model =
    let count = List.length active.users
        joinedCall = isJoinedCall active.conversationId model
        countText =
            if count == 0 then
                "No one connected"
            else
                String.fromInt count ++ " participant" ++ (if count /= 1 then "s" else "")
        duration = floor (toFloat (model.serverTime - active.startTime) / 1000)
        minutes = String.fromInt (duration // 60)
        seconds = String.fromInt (modBy 60 duration) |> String.padLeft 2 '0'
    in div [ class "dm-call-bar" ]
        [ div [ class "dm-call-bar-main" ]
            [ span [ class "dm-call-bar-icon" ] [ span [ class "live-dot", attribute "aria-hidden" "true" ] [] ]
            , span [ class "dm-call-bar-title" ] [ text (if joinedCall then "In Call" else "Call active") ]
            , span
                ([ class ("dm-call-bar-timer" ++ if joinedCall then " pw-live-call-timer" else "") ]
                    ++ (if joinedCall then [ attribute "data-call-start" (String.fromInt active.startTime) ] else [])
                )
                [ text (if joinedCall then minutes ++ ":" ++ seconds else "Ready to join") ]
            , span [ class "dm-call-bar-count" ] [ text countText ]
            ]
        , div [ class "dm-call-bar-controls" ]
            (if joinedCall then
                [ button [ class ("btn icon-btn" ++ if model.voice.muted then " call-muted" else ""), onClick (BridgeEvent "toggle_mute" E.null) ]
                    [ callIcon (if model.voice.muted then "mic off" else "mic") ]
                , button [ class ("btn icon-btn" ++ if model.voice.deafened then " call-muted" else ""), onClick (BridgeEvent "toggle_deafen" E.null) ]
                    [ callIcon (if model.voice.deafened then "audio off" else "audio") ]
                , button [ class "btn icon-btn", onClick (BridgeEvent "toggle_speaker" E.null) ]
                    [ callIcon "audio" ]
                , button [ class "btn call-decline", onClick EndCall ]
                    [ text "Leave" ]
                ]
             else
                [ button [ class "btn call-accept", onClick (JoinCall active.conversationId) ] [ text "Join Call" ] ]
            )
        ]

channelChatHeader : Int -> Model -> Html Msg
channelChatHeader channelId model =
    let
        channel =
            model.currentServer
                |> Maybe.andThen (\data -> data.channels |> List.filter (\item -> item.id == channelId) |> List.head)

        channelName = channel |> Maybe.map .name |> Maybe.withDefault "Channel"
        channelTopic = channel |> Maybe.map .topic |> Maybe.withDefault ""
    in
    div [ class "chat-header channel-chat-header" ]
        [ button [ class "chat-mobile-menu", type_ "button", onClick ToggleSidebar, attribute "aria-label" "Open navigation" ] [ span [ class "ui-icon ui-icon-menu", attribute "aria-hidden" "true" ] [] ]
        , span [ class "channel-header-mark", attribute "aria-hidden" "true" ] [ text "#" ]
        , div [ class "grow" ]
            [ h2 [] [ text channelName ]
            , if String.isEmpty (String.trim channelTopic) then
                small [ class "muted" ] [ text "Text channel" ]
              else
                small [ class "muted" ] [ text channelTopic ]
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
        , span [] [ text (if model.wsConnected then "Online" else "Reconnecting") ]
        ]

groupedMessageViews : Model -> List Message -> List (Html Msg)
groupedMessageViews model messages =
    messages
        |> List.foldl
            (\message ( previous, rendered ) ->
                let grouped = shouldGroup previous message
                in ( Just message, messageView model grouped message :: rendered )
            )
            ( Nothing, [] )
        |> Tuple.second
        |> List.reverse

shouldGroup : Maybe Message -> Message -> Bool
shouldGroup previous message =
    case previous of
        Just prev ->
            prev.userId == message.userId
                && message.replyTo == Nothing
                && prev.id >= 0
                && message.id >= 0
                && message.createdAt - prev.createdAt >= 0
                && message.createdAt - prev.createdAt < 420000
        Nothing ->
            False

messageView : Model -> Bool -> Message -> Html Msg
messageView model grouped m =
    let mine = case model.me of
            Just user -> user.id == m.userId
            Nothing -> False
        failed = Set.member m.id model.failedMsgIds
    in div [ class ("msg" ++ (if mine then " mine" else "") ++ (if grouped then " compact" else "") ++ (if m.id < 0 then " pending" else "") ++ (if failed then " failed" else "")), attribute "data-mid" (String.fromInt m.id), onContextMenu (OpenMessageCtx m) ]
        [ if grouped then div [ class "avatar avatar-spacer" ] [] else presenceAvatar model.userStatuses m.userId m.avatarUrl m.displayName ""
        , div [ class "msg-main" ]
            [ if grouped then
                timestampButton model "msg-time compact-time" m
              else
                div [ class "msg-head" ]
                    [ b [ class "msg-name", onClick (ShowUserPopup m.userId) ] [ text m.displayName ]
                    , timestampButton model "msg-time" m
                    , if mine then span [ class "pill self-pill" ] [ text "you" ] else text ""
                    ]
            , case m.replyTo of
                Just r -> div [ class "reply-preview" ] [ span [ class "reply-line" ] [], span [ class "reply-author" ] [ text r.displayName ], span [] [ text r.body ] ]
                Nothing -> text ""
            , div [ class "msg-body" ] (renderMessageBody m.body)
            , if failed then
                div [ class "msg-failed-bar" ]
                    [ span [ class "msg-failed-text" ] [ text "Failed to send" ]
                    , button [ class "msg-action", onClick (RetryMessage m.id) ] [ text "Retry" ]
                    , button [ class "msg-action danger", onClick (DismissFailedMessage m.id) ] [ text "Dismiss" ]
                    ]
              else text ""
            , div [ class "msg-actions" ]
                [ button [ class "msg-action", onClick (SetReplyTo m) ] [ text "Reply" ]
                , button [ class "msg-action", onClick (CopyText m.body) ] [ text "Copy" ]
                , if mine then button [ class "msg-action danger", onClick (DeleteMessage m.id) ] [ text "Delete" ] else text ""
                ]
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

composerView : String -> String -> Model -> Html Msg
composerView key placeholderText model =
    div [ class "composer", attribute "data-draft" key ]
        [ case model.replyTo of
            Just reply ->
                div [ class "reply-bar" ]
                    [ span [ class "reply-to-label" ] [ text ("Replying to " ++ reply.displayName) ]
                    , span [ class "reply-preview-text", title reply.body ] [ text ("“" ++ ellipsize 96 reply.body ++ "”") ]
                    , button [ class "btn secondary", onClick CancelReply ] [ text "Cancel" ]
                    ]
            Nothing -> text ""
        , textarea [ id "compose", placeholder placeholderText, value model.inputText, onInput InputText, onComposerKeyDown model.chatEnterSends ] []
        , div [ class "composer-footer" ]
            [ button [ class "btn secondary attach-btn composer-action", type_ "button", title "Attach files or images", attribute "aria-label" "Attach files or images", onClick (BridgeEvent "pick_attachments" E.null) ]
                [ span [ class "ui-icon ui-icon-attach", attribute "aria-hidden" "true" ] []
                , span [ class "composer-action-label" ] [ text "Attach" ]
                ]
            , small [ class "muted composer-hint" ] [ text ("Paste images or attach files up to " ++ formatBytesShort model.uploadMaxBytes ++ ".") ]
            , button [ class "btn composer-send composer-action", disabled (String.isEmpty (String.trim model.inputText)), onClick SendMessage, attribute "aria-label" "Send message" ]
                [ span [ class "composer-action-label" ] [ text "Send" ]
                , span [ class "ui-icon ui-icon-send", attribute "aria-hidden" "true" ] []
                ]
            ]
        ]

renderMessageBody : String -> List (Html Msg)
renderMessageBody body =
    let lines = String.lines body
    in lines
        |> List.indexedMap (\index line ->
            case attachmentMarkup line of
                Just ( AttachmentImage, name, url ) ->
                    a [ class "message-image-link", href url, target "_blank", rel "noopener" ]
                        [ img [ class "message-image", src url, alt name, attribute "loading" "lazy" ] [] ]
                Just ( AttachmentAudio, name, url ) ->
                    div [ class "media-attachment pw-media-player pw-audio-player", attribute "data-media-url" url ]
                        [ audio [ class "pw-audio-element", src url, preload "metadata" ] []
                        , button [ type_ "button", class "pw-media-play", attribute "data-media-action" "play", attribute "aria-label" ("Play " ++ name) ] [ text "Play" ]
                        , div [ class "pw-media-copy" ]
                            [ div [ class "pw-media-heading" ]
                                [ b [ class "pw-media-name", title name ] [ text name ]
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
                    renderTextLine index (List.length lines) line
        )

renderTextLine : Int -> Int -> String -> Html Msg
renderTextLine index lineCount line =
    let
        pieces =
            String.split " " line
                |> List.map renderMessageToken
                |> List.intersperse (text " ")
        ending =
            if index < lineCount - 1 then
                [ br [] [] ]
            else
                []
    in
    span [] (pieces ++ ending)

renderMessageToken : String -> Html Msg
renderMessageToken token =
    let
        url = stripUrlSuffix token
        suffix = String.dropLeft (String.length url) token
    in
    if isHttpUrl url then
        span [ class "message-link-wrap" ]
            [ a
                [ class "message-link"
                , href url
                , target "_blank"
                , rel "noopener noreferrer"
                , attribute "data-embed-url" url
                ]
                [ text url ]
            , text suffix
            ]
    else
        text token

isHttpUrl : String -> Bool
isHttpUrl value =
    String.startsWith "https://" value || String.startsWith "http://" value

stripUrlSuffix : String -> String
stripUrlSuffix value =
    case String.right 1 value of
        "." -> stripUrlSuffix (String.dropRight 1 value)
        "," -> stripUrlSuffix (String.dropRight 1 value)
        "!" -> stripUrlSuffix (String.dropRight 1 value)
        "?" -> stripUrlSuffix (String.dropRight 1 value)
        ";" -> stripUrlSuffix (String.dropRight 1 value)
        ":" -> stripUrlSuffix (String.dropRight 1 value)
        ")" -> stripUrlSuffix (String.dropRight 1 value)
        "]" -> stripUrlSuffix (String.dropRight 1 value)
        _ -> value

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
                        let name = String.dropLeft (String.length prefix) left
                            ident = String.dropRight 1 idPart
                        in if String.isEmpty name || String.isEmpty ident || String.contains "/" ident then Nothing
                           else Just ( kind name, name, endpoint ++ ident )
                    _ -> Nothing
            else Nothing
        fileKind name =
            let lower = String.toLower name
                has extensions = List.any (\extension -> String.endsWith extension lower) extensions
            in if has [ ".mp3", ".wav", ".ogg", ".m4a", ".aac", ".flac", ".opus" ] then
                AttachmentAudio
               else if has [ ".mp4", ".webm", ".mov", ".m4v", ".ogv" ] then
                AttachmentVideo
               else
                AttachmentFile
    in case parse (always AttachmentImage) "![" "/api/files/" of
        Just value -> Just value
        Nothing ->
            case parse (always AttachmentImage) "![" "/api/media/" of
                Just value -> Just value
                Nothing -> parse fileKind "[" "/api/files/"

onComposerKeyDown : Bool -> Attribute Msg
onComposerKeyDown enterSends =
    custom "keydown"
        (D.map4
            (\key shift ctrl meta ->
                let shouldSend =
                        key == "Enter" &&
                        ((enterSends && not shift) || (not enterSends && (ctrl || meta)))
                in if shouldSend then
                    { message = SendMessage, stopPropagation = True, preventDefault = True }
                else
                    { message = NoOp, stopPropagation = False, preventDefault = False }
            )
            (D.field "key" D.string)
            (D.field "shiftKey" D.bool)
            (D.field "ctrlKey" D.bool)
            (D.field "metaKey" D.bool)
        )

renderNotificationsPage : Model -> Html Msg
renderNotificationsPage model =
    let unseen = List.length (List.filter (\n -> not n.seen) model.notifs)
    in
    div [ class "notifications-page page-stack" ]
        [ div [ class "page-heading notifications-head" ]
            [ div []
                [ span [ class "eyebrow" ] [ text "Inbox" ]
                , h1 [] [ text "Notifications" ]
                , p [ class "muted" ]
                    [ text (if unseen == 0 then "You're caught up." else String.fromInt unseen ++ " unread item" ++ (if unseen == 1 then "." else "s.")) ]
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
                List.map (notificationView model.serverTime) model.notifs
            )
        ]

notificationView : Int -> Notification -> Html Msg
notificationView now n =
    a [ class ("notification-row" ++ if n.seen then "" else " unseen"), href n.url, onClick (Go n.url) ]
        [ span [ class "notification-mark", attribute "aria-hidden" "true" ] []
        , div [ class "notification-copy" ]
            [ div [ class "notification-title-row" ]
                [ b [] [ text n.kind ]
                , span [ class "muted notif-time" ] [ text (relativeTime now n.createdAt) ]
                ]
            , p [] [ text n.body ]
            ]
        ]

relativeTime : Int -> Int -> String
relativeTime now timestamp =
    let elapsed = agoAt now timestamp
    in if elapsed == "now" || elapsed == "1s" then "just now"
       else if elapsed == "never" then ""
       else elapsed ++ " ago"

renderSearchPage : String -> Model -> Html Msg
renderSearchPage q model =
    let
        userCount = List.length model.searchUsers
        threadCount = List.length model.searchThreads
    in
    div [ class "search-page page-stack" ]
        [ div [ class "page-heading" ]
            [ div []
                [ span [ class "eyebrow" ] [ text "Search" ]
                , h1 [] [ text ("Results for “" ++ q ++ "”") ]
                , p [ class "muted" ] [ text (String.fromInt userCount ++ " people and " ++ String.fromInt threadCount ++ " discussions") ]
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
    div [ class "row", onClick (Go ("#thread/" ++ String.fromInt t.id)) ]
        [ avatarImg t.avatarUrl t.displayName ""
        , div [] [ b [] [ text t.title ], small [ class "muted" ] [ text (t.forumName ++ " · " ++ t.displayName) ] ]
        ]


-- HELPERS

parseRoute : String -> ActiveRoute
parseRoute raw =
    let s = if String.startsWith "/" raw then String.dropLeft 1 raw else raw
    in if s == "" || s == "home" then Home
    else if s == "forums" then Forums
    else if s == "dms" then Dms
    else if s == "friends" then Friends
    else if s == "settings" then Settings
    else if s == "new-server" then NewServer
    else if s == "notifications" then Notifications
    else if String.startsWith "forum/" s then ForumView (parseInt (String.dropLeft 6 s))
    else if String.startsWith "thread/" s then ThreadView (parseInt (String.dropLeft 7 s))
    else if String.startsWith "dm/" s then DmView (parseInt (String.dropLeft 3 s))
    else if String.startsWith "profile/" s then ProfileView (parseInt (String.dropLeft 8 s))
    else if String.startsWith "server/" s then ServerView (parseInt (String.dropLeft 7 s))
    else if String.startsWith "channel/" s then ChannelView (parseInt (String.dropLeft 8 s))
    else if String.startsWith "voice/" s then VoiceChannelView (parseInt (String.dropLeft 6 s))
    else if String.startsWith "invite/" s then InviteView (String.dropLeft 7 s)
    else if String.startsWith "search/" s then SearchView (String.dropLeft 7 s)
    else Home

parseInt : String -> Int
parseInt s = case String.toInt s of
    Just i -> i
    Nothing -> 0

sortConvs : List Conversation -> List Conversation
sortConvs convs =
    List.sortWith compareConvs convs

compareConvs : Conversation -> Conversation -> Order
compareConvs a b =
    let aUnread = a.unread > 0
        bUnread = b.unread > 0
    in
    case ( aUnread, bUnread ) of
        ( True, False ) -> LT
        ( False, True ) -> GT
        _ -> compare b.updatedAt a.updatedAt

fmtErr : String -> String
fmtErr err =
    case err of
        "invalid_registration" -> "Username must be 3-24 characters and password must be at least 10 characters."
        "username_taken" -> "That username is already taken."
        "server_exists" -> "You already have a server with that name."
        "channel_exists" -> "A channel with that name already exists in this server."
        "invalid_server_name" -> "Server name must be at least 2 characters."
        "invalid_channel_name" -> "Channel name is required."
        "invalid_channel" -> "That invite channel does not belong to this server."
        "invalid_invite" -> "That invite is invalid, expired, or has been revoked."
        "bad_login" -> "Username or password is incorrect."
        "registration_disabled" -> "Registration is disabled on this server."
        "invalid_json" -> "Could not send the form. Please try again."
        "database_unavailable" -> "The server database is temporarily unavailable."
        "database_timeout" -> "The server database timed out. Please try again."
        "rate_limited" -> "Too many attempts. Wait a moment and try again."
        "user_not_found" -> "One or more usernames could not be found. Check the spelling and try again."
        "too_many_members" -> "Group chats can contain up to 50 people."
        "forbidden" -> "That action is not allowed. A user may have blocked one of the selected accounts."
        _ -> err |> String.replace "_" " "

authValidationError : Model -> Maybe String
authValidationError model =
    let username = String.trim model.authUsername
        password = model.authPassword
    in if model.authBusy then
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

authReady : Model -> Bool
authReady model =
    authValidationError { model | authBusy = False } == Nothing

decodeApi : E.Value -> Msg
decodeApi val =
    case D.decodeValue apiDecoder val of
        Ok msg -> msg
        Err _ -> ApiError "" "" "request_failed"

apiDecoder : Decoder Msg
apiDecoder =
    D.map5 apiMsg
        (D.field "path" D.string)
        (D.field "method" D.string |> defaultValue "GET")
        (D.field "ok" D.bool)
        (D.oneOf [ D.field "data" D.value, D.succeed E.null ])
        (D.oneOf [ D.field "error" D.string, D.succeed "request_failed" ])

apiMsg : String -> String -> Bool -> E.Value -> String -> Msg
apiMsg path method ok data err =
    if ok then ApiSuccess path method data else ApiError path method err

ago : Int -> Int -> String
ago now t =
    agoAt now t

ellipsize : Int -> String -> String
ellipsize maxLen value =
    let trimmed = String.trim value
    in if String.length trimmed <= maxLen then
        trimmed
    else
        String.left maxLen trimmed ++ "..."

agoAt : Int -> Int -> String
agoAt now t =
    if t == 0 then "never"
    else if now <= 0 then "now"
    else
        let s = Basics.max 1 ((now - t) // 1000)
        in if s < 60 then String.fromInt s ++ "s"
        else let m = s // 60
        in if m < 60 then String.fromInt m ++ "m"
        else let h = m // 60
        in if h < 24 then String.fromInt h ++ "h"
        else String.fromInt (h // 24) ++ "d"

absoluteTime : Time.Zone -> Int -> String
absoluteTime zone t =
    let posix = Time.millisToPosix t
    in pad2 (Time.toHour zone posix) ++ ":" ++ pad2 (Time.toMinute zone posix)

pad2 : Int -> String
pad2 n =
    if n < 10 then "0" ++ String.fromInt n else String.fromInt n

fromApiField : String -> E.Value -> E.Value
fromApiField name val = case D.decodeValue (D.field name D.value) val of
    Ok v -> v
    Err _ -> E.null

fromApiFieldStr : String -> E.Value -> String
fromApiFieldStr name val = case D.decodeValue (D.field name D.string) val of
    Ok v -> v
    Err _ -> ""

fromApiFieldInt : String -> E.Value -> Int
fromApiFieldInt name val = case D.decodeValue (D.field name D.int) val of
    Ok v -> v
    Err _ -> 0

maybeInt : Maybe Int -> E.Value
maybeInt value =
    case value of
        Just i -> E.int i
        Nothing -> E.null

maybeIntString : Maybe Int -> String
maybeIntString value =
    case value of
        Just i -> String.fromInt i
        Nothing -> ""

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
    List.foldl (\value found -> if List.member value found then found else found ++ [ value ]) [] values

normalizeUsernameInput : String -> String
normalizeUsernameInput value =
    let trimmed = String.trim value
    in String.toLower (if String.startsWith "@" trimmed then String.dropLeft 1 trimmed else trimmed)

listAt : Int -> List a -> Maybe a
listAt idx items =
    if idx < 0 then Nothing
    else case items of
        [] -> Nothing
        x :: xs -> if idx == 0 then Just x else listAt (idx - 1) xs

encodeServer : Server -> E.Value
encodeServer server =
    E.object
        [ ("id", E.int server.id)
        , ("name", E.string server.name)
        , ("description", E.string server.description)
        , ("icon_url", E.string server.iconUrl)
        , ("banner_url", E.string server.bannerUrl)
        , ("accent_color", E.string server.accentColor)
        ]


-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions model =
    let
        clockInterval =
            if model.pageVisible then 30000 else 120000
        syncInterval =
            if not model.pageVisible then 300000
            else if model.wsConnected then 300000
            else 5000
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
