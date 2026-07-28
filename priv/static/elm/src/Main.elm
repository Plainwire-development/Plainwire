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
        "rtc_peer_connected" -> D.map2 SetCallPeerConnected (D.field "user_id" D.int) (D.field "connected" D.bool)
        "tick" -> D.succeed (Tick (Time.millisToPosix 0))
        "presence_state" -> D.field "data" D.value |> D.map PresenceState
        "presence_online" -> D.field "data" (D.map2 PresenceOnline (D.field "user_id" D.int) (D.field "status" D.string))
        "presence_offline" -> D.map PresenceOffline (D.field "data" D.int)
        "presence_status" -> D.field "data" (D.map2 PresenceStatus (D.field "user_id" D.int) (D.field "status" D.string))
        "status_change" -> D.map SetMyStatus (D.field "data" D.string)
        "rtc_join_failed" -> D.map RtcJoinFailed (D.field "data" D.string)
        _ -> D.succeed NoOp
    )

handleSyncData : E.Value -> Msg
handleSyncData val = case D.decodeValue decodeSyncData val of
    Ok d -> SilentSync True  -- will refetch
    Err _ -> NoOp


-- MAIN

main : Program (Maybe String) Model Msg
main = Browser.application
    { init = init, update = update, view = view
    , subscriptions = subscriptions, onUrlChange = \_ -> NoOp
    , onUrlRequest = \_ -> NoOp
    }


-- INIT

init : Maybe String -> Url -> Nav.Key -> ( Model, Cmd Msg )
init _ url _ =
    let active = parseRoute (Maybe.withDefault "" url.fragment)
    in
    ( { me = Nothing, csrf = "", serverTime = 0, timeZone = Time.utc, absoluteTimestamps = False
      , forums = [], threads = [], currentThread = Nothing, replies = []
      , servers = [], convs = [], conversationMembers = Dict.empty, friends = [], notifs = []
      , searchUsers = [], searchThreads = []
      , currentServer = Nothing, currentProfile = Nothing, invitePreview = Nothing
      , msg = [], nextBefore = Nothing, loadingOlderMessages = False, hasOlderMessages = True
      , active = active, serverCache = Dict.empty
      , drafts = Dict.empty, wsConnected = False, isLeader = False
      , tabId = "", subs = Set.empty
      , voice = { mode = Nothing, id = Nothing, stream = Nothing
                , peers = Dict.empty, users = Dict.empty
                , muted = False, deafened = False, screenShare = False }
      , callUI = { incoming = Nothing, outgoing = Nothing, active = Nothing }
      , callMode = Idle, soundEnabled = True, replyTo = Nothing
      , toast = Nothing, modal = Nothing, settingsTab = "profile"
      , inputText = "", sidebarOpen = False, serversSheetOpen = False, ctxMenu = Nothing
      , threadReply = "", searchQuery = ""
      , authMode = "login", authUsername = "", authBusy = False, authDisplayName = ""
      , authPassword = "", serverName = "", serverDescription = "", booting = True, userStatuses = Dict.empty
      , failedMsgIds = Set.empty, currentProfileRelationship = "none", currentProfileBlockedByMe = False
      , pendingMessages = Dict.empty
      , profileDisplayName = "", profileBio = ""
      , profileAvatarUrl = "", profileBannerUrl = ""
      , profileAvatarPreviewUrl = "", profileBannerPreviewUrl = ""
      , profileAvatarUploading = False, profileBannerUploading = False
      , profileStatus = "online", profileTheme = "system"
      , modalTitle = "", modalBody = "", modalUserIds = ""
      , friendsTab = "online", friendQuery = "", friendSearchAttempted = False
        , pendingConversationId = Nothing
        , collapsedCategories = Set.empty
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

        AuthMode m -> ( { model | authMode = m }, Cmd.none )
        AuthUsername s -> ( { model | authUsername = s }, Cmd.none )
        AuthDisplayName s -> ( { model | authDisplayName = s }, Cmd.none )
        AuthPassword s -> ( { model | authPassword = s }, Cmd.none )
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
            let elapsed = Time.posixToMillis now - model.serverTime
                shouldSync = model.me /= Nothing && elapsed > 15000
            in ( { model | serverTime = Time.posixToMillis now }
               , if shouldSync then apiSend (encodeApiRequest (ApiGet "/sync?since=0")) else Cmd.none
               )

        ToggleSound -> ( { model | soundEnabled = not model.soundEnabled }
                       , if not model.soundEnabled then playNotification True else Cmd.none )

        Logout -> ( model, apiSend (encodeApiRequest (ApiPost "/logout" (Just (E.object [])))) )

        SetSettingsTab t -> ( { model | settingsTab = t }, Cmd.none )

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
        ProfileTheme s -> ( { model | profileTheme = s }, bridgeSend (E.object [("tag", E.string "set_theme"), ("data", E.string s)]) )

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

        SetCallPeerConnected userId connected ->
            let
                updateUser u =
                    if u.userId == userId then
                        { u | connected = connected }
                    else
                        u
                updateActive active =
                    { active | users = List.map updateUser active.users }
            in
            ( { model | callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = Maybe.map updateActive model.callUI.active } }, Cmd.none )

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
        SubmitModal -> submitModal model

        InviteModal serverId ->
            if serverId == 0 then
                ( { model | modal = Just "join_invite", modalTitle = "", modalBody = "0", modalUserIds = "" }, Cmd.none )
            else
                ( { model | modal = Just ("invite:" ++ String.fromInt serverId), modalTitle = "", modalBody = "0", modalUserIds = "" }, Cmd.none )

        ChannelModal serverId ->
            ( { model | modal = Just ("channel:" ++ String.fromInt serverId), modalTitle = "", modalBody = "text" }, Cmd.none )

        EditServerModal server ->
            ( { model | modal = Just ("edit_server:" ++ String.fromInt server.id), modalTitle = server.name, modalBody = server.description, modalUserIds = server.iconUrl }, Cmd.none )

        EditConversationModal conversation ->
            ( model, bridgeSend (E.object [("tag", E.string "edit_conversation"), ("data", E.int conversation.id)]) )

        AddPeopleModal conversationId ->
            ( model, bridgeSend (E.object [("tag", E.string "add_people"), ("data", E.int conversationId)]) )

        ShowUserPopup userId ->
            ( model, setHash ("#profile/" ++ String.fromInt userId) )

        BridgeEvent tag data ->
            let cmd = bridgeSend (E.object [("tag", E.string tag), ("data", data)])
            in case tag of
                "join_voice" ->
                    case D.decodeValue D.int data of
                        Ok channelId -> ( { model | voice = updateVoiceMode "voice" channelId model.voice, callMode = InCall }, cmd )
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
                Ok statuses -> ( { model | userStatuses = statuses }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        PresenceOnline uid status ->
            ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )
        PresenceOffline uid ->
            ( { model | userStatuses = Dict.remove (String.fromInt uid) model.userStatuses }, Cmd.none )
        PresenceStatus uid status ->
            ( { model | userStatuses = Dict.insert (String.fromInt uid) status model.userStatuses }, Cmd.none )
        SetMyStatus status ->
            ( { model | profileStatus = status }, Cmd.none )
        RtcJoinFailed _ ->
            ( { model | voice = clearVoice model.voice, callMode = Idle, callUI = { incoming = model.callUI.incoming, outgoing = Nothing, active = Nothing } }, Cmd.none )

        StartScreenShare ->
            ( model, bridgeSend (E.object [("tag", E.string "start_screen_share"), ("data", E.null)]) )

        StopScreenShare ->
            let voice0 = model.voice
            in ( { model | voice = { voice0 | screenShare = False } }, bridgeSend (E.object [("tag", E.string "stop_screen_share"), ("data", E.null)]) )

        ToggleCategory catId ->
            let newSet = if Set.member catId model.collapsedCategories then Set.remove catId model.collapsedCategories else Set.insert catId model.collapsedCategories
            in ( { model | collapsedCategories = newSet }, Cmd.none )

        CreateCategoryModal serverId ->
            ( { model | modal = Just ("create_category:" ++ String.fromInt serverId), modalTitle = "New Category", modalBody = "" }, Cmd.none )

        SubmitCategory serverId name ->
            ( { model | modal = Nothing }, apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/categories") (Just (E.object [("name", E.string name)])))) )

        UpdateCategoryName serverId catId name ->
            ( model, apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/category/" ++ String.fromInt catId) (Just (E.object [("name", E.string name)])))) )

        DeleteCategory serverId catId ->
            ( model, apiSend (encodeApiRequest (ApiPost ("/server/" ++ String.fromInt serverId ++ "/category/" ++ String.fromInt catId ++ "/delete") Nothing)) )

        MoveChannelToCategory channelId catId ->
            ( model, apiSend (encodeApiRequest (ApiPost ("/channel/" ++ String.fromInt channelId ++ "/move") (Just (E.object [("category_id", E.null)]))) ))

        LoadMoreMessages ->
            if model.loadingOlderMessages || not model.hasOlderMessages then
                ( model, Cmd.none )
            else case ( model.active, model.msg ) of
                ( DmView id, firstMsg :: _ ) ->
                    ( { model | loadingOlderMessages = True }, Cmd.batch [ bridgeSend (E.object [("tag", E.string "preserve_message_scroll"), ("data", E.null)]), apiSend (encodeApiRequest (ApiGet ("/messages?scope=direct&scope_id=" ++ String.fromInt id ++ "&before=" ++ String.fromInt firstMsg.id))) ] )
                ( ChannelView id, firstMsg :: _ ) ->
                    ( { model | loadingOlderMessages = True }, Cmd.batch [ bridgeSend (E.object [("tag", E.string "preserve_message_scroll"), ("data", E.null)]), apiSend (encodeApiRequest (ApiGet ("/messages?scope=channel&scope_id=" ++ String.fromInt id ++ "&before=" ++ String.fromInt firstMsg.id))) ] )
                _ -> ( model, Cmd.none )

        _ -> ( model, Cmd.none )


handleMe : E.Value -> Model -> ( Model, Cmd Msg )
handleMe val model =
    case D.decodeValue decodeUser (fromApiField "user" val) of
                    Ok user ->
                        let
                            userValue = fromApiField "user" val
                            avatarSource = D.decodeValue (D.field "avatar_source_url" D.string) userValue |> Result.withDefault user.avatarUrl
                            bannerSource = D.decodeValue (D.field "banner_source_url" D.string) userValue |> Result.withDefault user.bannerUrl
                        in
                                ( { model | me = Just user
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
                                    , profileStatus = statusPreference (statusToString user.status)
                                    , profileTheme = user.theme
                                    }
                                , Cmd.batch
                                    [ bridgeSend (E.object [("tag", E.string "connect_ws"), ("data", E.null)])
                                    , bridgeSend (E.object [("tag", E.string "presence_update"), ("data", E.string (statusPreference (statusToString user.status)))])
                                    , apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                                    , routeCmd model.active
                                    ]
                                )
                    Err _ -> ( model, Cmd.none )


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
            in
            ( { model | msg = newMsgs, inputText = "", replyTo = Nothing, pendingMessages = cleanedPending }
            , apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
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
        Ok user -> ( { model | currentProfile = Just user, currentProfileRelationship = rel, currentProfileBlockedByMe = blockedByMe }, bridgeSend (E.object [("tag", E.string "set_theme"), ("data", E.string user.theme)]) )
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
    { voice | mode = Just mode, id = Just id }


clearVoice : VoiceState -> VoiceState
clearVoice voice =
    { voice | mode = Nothing, id = Nothing, screenShare = False, users = Dict.empty }


isCurrentServer : Int -> Model -> Bool
isCurrentServer serverId model =
    model.currentServer
        |> Maybe.map (\d -> d.server.id == serverId)
        |> Maybe.withDefault False


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
            ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), playNotification model.soundEnabled ] )
        Ok ( "channel_message", _ ) ->
            ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), playNotification model.soundEnabled ] )
        Ok ( "notification", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "friend_request", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "friend_accept", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "conversation_created", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "conversation_members_added", _ ) ->
            ( model, bridgeSend (E.object [("tag", E.string "silent_sync"), ("data", E.null)]) )
        Ok ( "call_incoming", ev ) ->
            handleCallIncoming ev model
        Ok ( "call_ringing", ev ) ->
            case D.decodeValue callOutgoingDecoder ev of
                Ok out ->
                    ( { model | callUI = { incoming = Nothing, outgoing = Just { conversationId = out.convId, userId = 0, displayName = out.displayName, avatarUrl = out.avatarUrl }, active = model.callUI.active }, callMode = Ringing }, playOutgoingRingtone True )
                Err _ ->
                    ( { model | callUI = { incoming = Nothing, outgoing = model.callUI.outgoing, active = model.callUI.active }, callMode = Ringing }, playOutgoingRingtone True )
        Ok ( "call_accepted", ev ) ->
            case D.decodeValue callAcceptedDecoder ev of
                Ok accepted ->
                    let
                        peer = { userId = accepted.userId, displayName = accepted.displayName, avatarUrl = accepted.avatarUrl, muted = False, deafened = False, connected = False }
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
                    ( { model | callUI = { incoming = Nothing, outgoing = Nothing, active = active }, callMode = Connected }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
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
                    let currentCid = case model.callUI.active of
                            Just a -> a.conversationId
                            Nothing -> 0
                        isCurrentCall = cid == currentCid || currentCid == 0
                    in if not isCurrentCall then
                        ( model, Cmd.none )
                       else
                        let existing = Maybe.andThen (\a -> if a.conversationId == cid then Just a else Nothing) model.callUI.active
                            existingUsers = Maybe.withDefault [] (Maybe.map .users existing)
                            myId = Maybe.withDefault 0 (Maybe.map .id model.me)
                            mergeConnected u =
                                let wasConnected = List.any (\e -> e.userId == u.userId && e.connected) existingUsers
                                    isSelf = u.userId == myId
                                in { u | connected = wasConnected || isSelf }
                            safeUsers =
                                if List.isEmpty users && isJoinedCall cid model then
                                    Maybe.withDefault [] (Maybe.map .users existing)
                                else
                                    List.map mergeConnected users
                            active = { conversationId = cid, users = safeUsers
                                , startTime = Maybe.withDefault model.serverTime (Maybe.map .startTime existing)
                                , expanded = Maybe.withDefault False (Maybe.map .expanded existing)
                                }
                        in ( { model | callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = Just active } }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        Ok ( "call_peer_joined", ev ) ->
            case D.decodeValue callPeerJoinedDecoder ev of
                Ok peer ->
                    let addUser users =
                            if List.any (\u -> u.userId == peer.userId) users then
                                users
                            else
                                users ++ [ peer ]
                        updateActive a = { a | users = addUser a.users }
                    in ( { model | callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = Maybe.map updateActive model.callUI.active } }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        Ok ( "call_peer_left", ev ) ->
            case D.decodeValue (D.field "user_id" D.int) ev of
                Ok uid ->
                    let removeUser users = List.filter (\u -> u.userId /= uid) users
                        updateActive a = { a | users = removeUser a.users }
                    in ( { model | callUI = { incoming = model.callUI.incoming, outgoing = model.callUI.outgoing, active = Maybe.map updateActive model.callUI.active } }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        Ok ( "call_signal", ev ) -> ( model, Cmd.none )
        Ok ( "voice_state", ev ) ->
            case D.decodeValue voiceStateDecoder ev of
                Ok ( channelId, users ) ->
                    let
                        userDict = Dict.fromList (List.map (\u -> ( u.userId, u )) users)
                        voice0 = model.voice
                    in
                    -- mode is set by the join handler before voice_state arrives
                    -- so Nothing means user already left: ignore stale events
                    case voice0.mode of
                        Just "voice" ->
                            ( { model | voice = { voice0 | id = Just channelId, users = userDict }, callMode = InCall }, Cmd.none )
                        _ ->
                            ( model, Cmd.none )
                Err _ ->
                    ( model, Cmd.none )
        Ok ( "voice_peer_left", ev ) ->
            case D.decodeValue (D.field "user_id" D.int) ev of
                Ok uid ->
                    let voice0 = model.voice
                    in ( { model | voice = { voice0 | users = Dict.remove uid model.voice.users } }, Cmd.none )
                Err _ ->
                    ( model, Cmd.none )
        Ok ( "voice_user_joined", ev ) -> ( model, Cmd.none )
        Ok ( "voice_user_left", ev ) -> ( model, Cmd.none )
        Ok ( "voice_signal", ev ) -> ( model, Cmd.none )
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
            case ( D.decodeValue (D.field "server_id" D.int) ev, D.decodeValue (D.field "category_id" D.int) ev ) of
                ( Ok serverId, Ok _ ) ->
                    if isCurrentServer serverId model then
                        ( model, apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt serverId))) )
                    else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        Ok ( "category_updated", ev ) ->
            case D.decodeValue (D.field "server_id" D.int) ev of
                Ok serverId ->
                    if isCurrentServer serverId model then
                        ( model, apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt serverId))) )
                    else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        Ok ( "category_deleted", ev ) ->
            case D.decodeValue (D.field "server_id" D.int) ev of
                Ok serverId ->
                    if isCurrentServer serverId model then
                        ( model, apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt serverId))) )
                    else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        Ok ( "categories_reordered", ev ) ->
            case D.decodeValue (D.field "server_id" D.int) ev of
                Ok serverId ->
                    if isCurrentServer serverId model then
                        ( model, apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt serverId))) )
                    else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        Ok ( "channel_moved", ev ) ->
            case D.decodeValue (D.field "server_id" D.int) ev of
                Ok serverId ->
                    if isCurrentServer serverId model then
                        ( model, apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt serverId))) )
                    else ( model, Cmd.none )
                _ -> ( model, Cmd.none )
        _ -> ( model, Cmd.none )


wsEventDecoder : Decoder ( String, E.Value )
wsEventDecoder =
    D.map2 Tuple.pair
        (D.field "type" D.string)
        D.value

handleMessageCreated : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageCreated ev model =
    case D.decodeValue (D.field "message" decodeMessage) ev of
        Ok message ->
            if messageApplies model.active message then
                ( { model | msg = List.filter (\m -> m.id /= message.id) model.msg ++ [ message ] }
                , Cmd.batch
                    [ playNotification model.soundEnabled
                    , bridgeSend (E.object [("tag", E.string "scroll_messages_to_bottom"), ("data", E.null)])
                    ]
                )
            else
                ( model, Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), playNotification model.soundEnabled ] )
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
                , outgoing = Nothing, active = Nothing }
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

voiceStateDecoder : Decoder ( Int, List { userId : Int, muted : Bool, deafened : Bool, screen : Bool } )
voiceStateDecoder =
    D.map2 Tuple.pair
        (D.field "channel_id" D.int)
        (D.field "users" (D.list voiceUserDecoder))

voiceUserDecoder : Decoder { userId : Int, muted : Bool, deafened : Bool, screen : Bool }
voiceUserDecoder =
    D.map4 (\uid muted deafened screen -> { userId = uid, muted = muted, deafened = deafened, screen = screen })
        (D.field "user_id" D.int)
        (D.field "muted" D.bool |> defaultValue False)
        (D.field "deafened" D.bool |> defaultValue False)
        (D.field "screen" D.bool |> defaultValue False)

callPeerJoinedDecoder : Decoder CallUser
callPeerJoinedDecoder =
    D.map6 CallUser
        (D.field "user_id" D.int)
        (D.oneOf [ D.at [ "profile", "display_name" ] D.string, D.succeed "Unknown" ])
        (D.oneOf [ D.at [ "profile", "avatar_url" ] D.string, D.succeed "" ])
        (D.succeed False)
        (D.succeed False)
        (D.succeed False)


-- VIEW

view : Model -> Browser.Document Msg
view model =
    { title = titleText model
    , body =
        [ if model.booting then div [ class "boot" ] [ text "Loading Plainwire…" ]
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
    in if unread > 0 then "(" ++ String.fromInt unread ++ ") Plainwire" else "Plainwire"


renderToast : Model -> Html Msg
renderToast model = case model.toast of
    Just msg ->
        div [ class "toast toast-visible" ]
            [ span [ class "toast-text" ] [ text msg ]
            , button [ class "toast-close", onClick DismissToast ] [ text "✕" ]
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
                    , small [ class "muted" ] [ text "Images, GIFs, and files up to 250 MB." ]
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
        [ modalHead "Create channel" "Add a text or voice room."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Channel name" ], input [ value model.modalTitle, placeholder "general, updates, voice-chat", onInput ModalTitle ] [] ]
            , div [ class "field" ]
                [ label [] [ text "Type" ]
                , select [ value model.modalBody, onInput ModalBody ]
                    [ option [ value "text" ] [ text "Text" ]
                    , option [ value "voice" ] [ text "Voice" ]
                    ]
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
        [ modalHead "Create invite" "Copy a join link for this server."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Channel ID optional" ], input [ value model.modalUserIds, placeholder "Leave blank for server invite", onInput ModalUserIds ] [] ]
            , div [ class "field" ] [ label [] [ text "Max uses" ], input [ value model.modalBody, placeholder "0 for unlimited", onInput ModalBody ] [] ]
            , p [ class "muted modal-hint" ] [ text "Existing matching invites are reused instead of creating duplicates." ]
            ]
        , modalActions "Copy invite"
        ]
    else if String.startsWith "edit_server:" kind then
        [ modalHead "Customize server" "Update the name, description, and icon."
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "Server name" ], input [ value model.modalTitle, placeholder "Server name", onInput ModalTitle ] [] ]
            , div [ class "field" ] [ label [] [ text "Description" ], textarea [ value model.modalBody, placeholder "What is this server for?", onInput ModalBody ] [] ]
            , div [ class "field" ] [ label [] [ text "Icon URL" ], input [ value model.modalUserIds, placeholder "https://...", onInput ModalUserIds ] [] ]
            ]
        , modalActions "Save server"
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
    let inCall = model.callMode == Connected || model.callMode == InCall || model.callMode == Ringing
        showInCall = inCall || model.voice.mode == Just "call" || model.voice.mode == Just "voice"
        popups = List.filterMap identity
            [ Maybe.map (\i -> renderCallPopup "incoming" i model) model.callUI.incoming
            , Maybe.map (\o -> renderCallPopup "outgoing" o model) model.callUI.outgoing
            ]
        activeOverlay = case ( showInCall, model.callUI.active ) of
            ( True, Just active ) ->
                let joinedCall = isJoinedCall active.conversationId model
                in if not joinedCall && List.isEmpty active.users then
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
        ringHtml = if kind == "incoming" then
            div [] [ div [ class "call-ring" ] [], div [ class "call-ring delay" ] [] ] else div [] []
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
        [ div [ class "call-popup-head" ]
            [ div [ class "call-avatar-wrap" ]
                [ avatarHtml, ringHtml ]
            , div []
                [ p [ class "call-popup-title" ] [ text popup.displayName ]
                , p [ class "call-popup-sub" ] [ text (if kind == "incoming" then "Incoming call" else "Calling...") ]
                ]
            ]
        , actions
        ]

renderCompactCallBar : ActiveCall -> Model -> Html Msg
renderCompactCallBar active model =
    let count = List.length active.users
        countText = if count == 0 then "Connecting..." else String.fromInt count ++ " participant" ++ (if count /= 1 then "s" else "")
        userAvatars = List.take 3 active.users
            |> List.map (\u -> avatarImg u.avatarUrl u.displayName "small")
        overflow = count - 3
    in div [ class "call-bar compact", onClick ToggleCallOverlay ]
        [ div [ class "call-bar-icon" ] [ text "♪" ]
        , div [ class "call-bar-info" ]
            [ span [ class "call-bar-title" ] [ text "In Call" ]
            , span [ class "call-bar-sub" ] [ text countText ]
            ]
        , div [ class "call-bar-avatars" ] (userAvatars ++
            (if overflow > 0 then [ div [ class "avatar small" ] [ text ("+" ++ String.fromInt overflow) ] ] else [])
          )
        , div [ class "call-bar-controls" ]
            [ button [ class ("btn icon-btn" ++ if model.voice.muted then " call-muted" else ""), title "Toggle mute", onClickStop (BridgeEvent "toggle_mute" E.null) ]
                [ text (if model.voice.muted then "🔇" else "🎤") ]
            , button [ class ("btn icon-btn" ++ if model.voice.deafened then " call-muted" else ""), title "Toggle deafen", onClickStop (BridgeEvent "toggle_deafen" E.null) ]
                [ text (if model.voice.deafened then "🔇" else "🔊") ]
            , if model.voice.screenShare then
                button [ class "btn icon-btn share-active", title "Stop screen share", onClickStop StopScreenShare ]
                    [ text "🖥" ]
              else
                button [ class "btn icon-btn", title "Share screen", onClickStop StartScreenShare ]
                    [ text "📺" ]
            , button [ class "btn icon-btn call-decline", title "Leave call", onClickStop EndCall ]
                [ text "✕" ]
            ]
        ]

renderExpandedCallOverlay : ActiveCall -> Model -> Html Msg
renderExpandedCallOverlay active model =
    let duration = floor (toFloat (model.serverTime - active.startTime) / 1000)
        minutes = String.fromInt (duration // 60)
        seconds = String.fromInt (modBy 60 duration) |> String.padLeft 2 '0'
        timerText = minutes ++ ":" ++ seconds
    in div [ class "call-overlay expanded" ]
        [ div [ class "call-overlay-header" ]
            [ div [ class "call-overlay-title" ]
                [ span [ class "call-overlay-icon" ] [ text "♪" ]
                , span [] [ text "In Call" ]
                , span [ class "call-overlay-timer" ] [ text timerText ]
                ]
            , button [ class "btn icon-btn", title "Minimize", onClick ToggleCallOverlay ] [ text "─" ]
            ]
        , div [ class "call-overlay-users" ]
            (if List.isEmpty active.users then
                [ div [ class "call-empty" ] [ text "Connecting audio..." ] ]
             else
                List.map renderCallUser active.users)
        , div [ class "call-overlay-controls" ]
            [ button [ class ("btn" ++ if model.voice.muted then " call-muted" else " secondary"), onClick (BridgeEvent "toggle_mute" E.null) ]
                [ text (if model.voice.muted then "🔇 Unmute" else "🎤 Mute") ]
            , button [ class ("btn" ++ if model.voice.deafened then " call-muted" else " secondary"), onClick (BridgeEvent "toggle_deafen" E.null) ]
                [ text (if model.voice.deafened then "🔇 Undeafen" else "🔊 Deafen") ]
            , button [ class "btn secondary", onClick (BridgeEvent "unlock_audio" E.null) ] [ text "Enable audio" ]
            , button [ class "btn secondary", onClick (BridgeEvent "toggle_speaker" E.null) ] [ text "🔈 Speaker" ]
            , button [ class "btn call-decline", onClick EndCall ] [ text "✕" ]
            ]
        ]

renderCallUser : CallUser -> Html Msg
renderCallUser u =
    let
        avatarClass = "small" ++ if u.connected && not u.muted then " live" else ""
        statusText =
            if u.muted then
                "Muted"
            else if u.deafened then
                "Deafened"
            else if u.connected then
                "Connected"
            else
                "Connecting"
    in div [ class "call-user-row" ]
        [ avatarImg u.avatarUrl u.displayName avatarClass
        , div [ class "call-user-info" ]
            [ span [ class "call-user-name" ] [ text u.displayName ]
            , span [ class ("call-user-status" ++ if u.muted then " muted" else if u.deafened then " deafened" else "") ]
                [ text statusText ]
            ]
        ]


avatarImg : String -> String -> String -> Html Msg
avatarImg url name cls =
    if String.isEmpty url then
        div [ class ("avatar " ++ cls) ]
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
    in div [ class "presence-avatar", title label, attribute "aria-label" (name ++ " — " ++ label) ]
        [ avatarImg url name cls
        , span [ class ("avatar-presence-dot " ++ presence), attribute "aria-hidden" "true" ] []
        ]


-- AUTH VIEW

renderAuth : Model -> Html Msg
renderAuth model =
    div [ class "layout auth-layout" ]
        [ div [] []
        , main_ [ class "main" ]
            [ div [ class "content" ]
                [ div [ class "card pad auth-card" ]
                    [ h1 [] [ text "Plainwire" ]
                    , p [ class "muted" ] [ text "Chat with your friends and communities." ]
                    , div [ class "tabs" ]
                        [ button [ class "btn", onClick (AuthMode "login") ] [ text "Login" ]
                        , button [ class "btn secondary", onClick (AuthMode "register") ] [ text "Register" ]
                        ]
                    , div []
                        [ div [ class "field" ]
                            [ label [] [ text "Username" ]
                            , input [ id "u", type_ "text", attribute "autocomplete" "username"
                                    , value model.authUsername, onInput AuthUsername ] []
                            ]
                        , if model.authMode == "register" then
                            div [ class "field" ]
                                [ label [] [ text "Display name" ]
                                , input [ id "d", type_ "text", value model.authDisplayName, onInput AuthDisplayName ] []
                                ]
                          else text ""
                        , div [ class "field" ]
                            [ label [] [ text "Password" ]
                            , input [ id "p", type_ "password", attribute "autocomplete" (if model.authMode == "login" then "current-password" else "new-password")
                                    , value model.authPassword, onInput AuthPassword ] []
                            ]
                        , if model.authMode == "register" then
                            p [ class "muted auth-hint" ] [ text "Username: 3-24 characters. Password: at least 8 characters." ]
                          else text ""
                        , case authValidationError { model | authBusy = False } of
                            Just err -> p [ class "auth-error" ] [ text err ]
                            Nothing -> text ""
                        , button [ class "btn", disabled (model.authBusy || not (authReady model)), onClick DoAuth ]
                            [ text (if model.authBusy then "Please wait..." else if model.authMode == "login" then "Login" else "Create account") ]
                        ]
                    ]
                ]
            ]
        ]


-- APP SHELL

renderApp : Model -> Html Msg
renderApp model =
    div [ class "layout" ]
        [ renderRail model
        , renderSideForRoute model
        , main_ [ class "main" ]
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
            [ h3 [] [ text "Servers" ]
            , if List.isEmpty model.servers then
                p [ class "muted" ] [ text "No servers yet." ]
              else
                div [] (List.map (\s -> serverSheetRow s model) model.servers)
            , div [ style "margin-top" "12px", class "nav-actions" ]
                [ button [ class "btn", onClick (Go "#new-server") ] [ text "New Server" ]
                , button [ class "btn secondary", onClick (InviteModal 0) ] [ text "Use Invite" ]
                ]
            , button [ class "btn secondary", style "margin-top" "8px", onClick CloseServersSheet ] [ text "Close" ]
            ]
        ]

serverSheetRow : Server -> Model -> Html Msg
serverSheetRow s model =
    let isActive = case model.active of
            ServerView id -> id == s.id
            ChannelView _ -> Maybe.map (.id << .server) model.currentServer == Just s.id
            VoiceChannelView _ -> Maybe.map (.id << .server) model.currentServer == Just s.id
            _ -> False
    in div [ class ("server-sheet-row" ++ if isActive then " active" else "")
           , onClick (Go ("#server/" ++ String.fromInt s.id))
           ]
        [ serverIcon s
        , div [ class "grow" ]
            [ b [] [ text s.name ]
            , small [] [ text (s.role ++ " · " ++ String.fromInt s.memberCount ++ " members") ]
            ]
        ]


renderRail : Model -> Html Msg
renderRail model =
    nav [ class "rail" ]
        ([ div [ class "mark", title "Plainwire" ] []
         , railBtn "⌂" (model.active == Home) (Go "#")
         , railBtn "F" (model.active == Forums) (Go "#forums")
         , railBtn "D" (isDmActive model) (Go "#dms")
         , railBtn "+" (model.active == Friends) (Go "#friends")
         , div [ class "rail-spacer" ] []
         ] ++ List.map (\s -> renderServerIcon s model) (List.take 8 model.servers)
         ++ [ railBtn "⚙" (model.active == Settings) (Go "#settings") ])

railBtn : String -> Bool -> Msg -> Html Msg
railBtn label active msg =
    button [ class ("rail-btn" ++ if active then " active" else "")
           , onClick msg
           ]
        [ text label ]

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
             ] ++ List.map (\s -> serverRow s model) model.servers
             ++ [ dmHeader model ]
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
            if List.isEmpty channels then
                []
            else
                [ div [ class "channel-group-title clickable", onClick (ToggleCategory cat.id) ]
                    [ text (if isCollapsed cat.id then "▶ " else "▼ ")
                    , text cat.name
                    , if canManage then
                        span [ class "category-actions" ]
                            [ span [ class "ctx-trigger", stopClick, onClick (CreateCategoryModal data.server.id) ] [ text "+" ] ]
                      else text ""
                    ]
                ] ++ (if isCollapsed cat.id then [] else List.map channelRow channels)
        sortedCategories = List.sortBy .position data.categories
        canManage = model.currentServer |> Maybe.map (\d -> d.server.role == "owner" || d.server.role == "admin") |> Maybe.withDefault False
    in
    aside [ class ("side" ++ if model.sidebarOpen then " open" else "") ]
        [ div [ class "side-head" ]
            [ serverIcon data.server
            , h1 [] [ text data.server.name ]
            , small [] [ text data.server.description ]
            , div [ class "nav-actions" ]
                [ button [ class "btn secondary", onClick (InviteModal data.server.id) ] [ text "Invite" ]
                , button [ class "btn secondary", onClick (ChannelModal data.server.id) ] [ text "Channel" ]
                , button [ class "btn secondary", onClick (EditServerModal data.server) ] [ text "Edit" ]
                ]
            ]
        , div [ class "list server-channel-list" ]
            (channelGroup "Text channels" (List.filter (\c -> c.categoryId == Nothing) textChannels)
             ++ List.concatMap (\cat -> categoryBlock cat (List.filter (\c -> c.categoryId == Just cat.id) textChannels)) sortedCategories
             ++ channelGroup "Voice channels" (List.filter (\c -> c.categoryId == Nothing) voiceChannels)
             ++ List.concatMap (\cat -> categoryBlock cat (List.filter (\c -> c.categoryId == Just cat.id) voiceChannels)) sortedCategories)
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
        [ h1 [] [ text "Plainwire" ]
        , small [] [ text "Chat app" ]
        , div [ class "nav-actions" ]
            [ button [ class "btn secondary", onClick (Go "#new-server") ] [ text "New server" ]
            , button [ class "btn secondary", onClick (InviteModal 0) ] [ text "Use invite" ]
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
    in a [ class "row", onClick (Go "#notifications") ]
        [ span [ class "badge", if unread == 0 then attribute "data-zero" "1" else attribute "data-zero" "0" ]
            [ if unread > 0 then text (String.fromInt unread) else text "" ]
        , div [ class "grow" ]
            [ b [] [ text "Notifications" ]
            , small [ class "muted" ] [ text "live updates" ]
            ]
        ]

friendsRow : Model -> Html Msg
friendsRow model =
    let pending = List.length (List.filter (\f -> f.incoming) model.friends)
    in a [ class "row", onClick (Go "#friends") ]
        [ span [ class "server-icon" ] [ text "☻" ]
        , div [ class "grow" ]
            [ b [] [ text "Friends" ], small [ class "muted" ] [ text "requests and contacts" ] ]
        , if pending > 0 then span [ class "badge" ] [ text (String.fromInt pending) ] else text ""
        ]

serverRow : Server -> Model -> Html Msg
serverRow s model =
    let isActive = case model.active of
            ServerView id -> id == s.id
            _ -> False
    in a [ class ("row" ++ if isActive then " active" else "")
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
    div [ class "row" ]
        [ div [ class "grow" ]
            [ b [] [ text "Direct Messages" ]
            , small [ class "muted" ] [ text "private and group chats" ]
            ]
        , button [ class "btn secondary", onClick NewDmModal ] [ text "New" ]
        ]

messageRequestsNav : Int -> Html Msg
messageRequestsNav count =
    a [ class "row message-requests-nav", onClick (Go "#dms") ]
        [ span [ class "server-icon" ] [ text "?" ]
        , div [ class "grow" ] [ b [] [ text "Message Requests" ], small [ class "muted" ] [ text "Review before replying" ] ]
        , span [ class "badge" ] [ text (String.fromInt count) ]
        ]

convRow : Conversation -> Model -> Html Msg
convRow c model =
    let isActive = case model.active of
            DmView id -> id == c.id
            _ -> False
        lastText = Maybe.withDefault "No messages yet" c.lastBody
    in a [ class ("row dm-row" ++ (if isActive then " active" else "") ++ (if c.unread > 0 then " unread" else ""))
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
userPanel model = case model.me of
    Just u ->
        div [ class "user-panel" ]
            [ presenceAvatar model.userStatuses u.id u.avatarUrl u.displayName ""
            , div [ class "grow" ]
                [ b [] [ text u.displayName ]
                , small [] [ text (statusToString u.status) ]
                ]
            , div [ class "user-panel-actions" ]
                [ button [ title "Settings", onClick (Go "#settings") ] [ text "⚙" ] ]
            ]
    Nothing -> text ""


renderMobileNav : Model -> Html Msg
renderMobileNav model =
    nav [ class "mobile-nav" ]
        [ mobileBtn "⌂" "Home" (model.active == Home) (Go "#")
        , mobileBtn "r/" "Forums" (model.active == Forums) (Go "#forums")
        , mobileBtn "D" "DMs" (isDmActive model) (Go "#dms")
        , mobileBtn "+" "Friends" (model.active == Friends) (Go "#friends")
        , mobileBtn "≡" "Servers" model.serversSheetOpen ToggleServersSheet
        , mobileBtn "⚙" "You" (model.active == Settings) (Go "#settings")
        , if List.isEmpty model.servers then text "" else
            div [ class "mobile-server-dots" ]
                (List.map (\s ->
                    span [ class ("mobile-server-dot" ++ if serverIsActive s model then " active" else "")
                         , onClick (Go ("#server/" ++ String.fromInt s.id))
                         , title s.name
                         ] [ text (String.left 1 s.name) ]
                ) (List.take 4 model.servers))
        ]

mobileBtn : String -> String -> Bool -> Msg -> Html Msg
mobileBtn icon label active msg =
    button [ class ("mobile-nav-btn" ++ if active then " active" else "")
           , onClick msg
           ]
        [ span [ class "mobile-nav-icon" ] [ text icon ]
        , span [ class "mobile-nav-label" ] [ text label ]
        ]


renderTopbar : Model -> Html Msg
renderTopbar model =
    div [ class "topbar" ]
        [ button [ class "sidebar-toggle", onClick ToggleSidebar ] [ text "☰" ]
        , h2 [] [ text (topbarTitle model) ]
        ]

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
    let unreadNotifs = List.length (List.filter (\n -> not n.seen) model.notifs)
        unreadDms = List.sum (List.map (\c -> c.unread) model.convs)
        recentConvs = List.take 4 (sortConvs model.convs)
    in div [ class "home-page" ]
        [ section [ class "hero-card" ]
            [ div []
                [ span [ class "eyebrow" ] [ text "Plainwire" ]
                , h1 [] [ text "Chat, threads, DMs, and voice." ]
                , p [] [ text "Talk with friends, join communities, and keep conversations organized." ]
                ]
            , div [ class "hero-actions" ]
                [ button [ class "btn", onClick (Go "#forums") ] [ text "Browse threads" ]
                , button [ class "btn secondary", onClick (Go "#new-server") ] [ text "Create server" ]
                ]
            ]
        , div [ class "stat-grid" ]
            [ statCard "Servers" (String.fromInt (List.length model.servers)) "joined" (Go "#")
            , statCard "DM unread" (String.fromInt unreadDms) "private messages" (Go "#dms")
            , statCard "Notifications" (String.fromInt unreadNotifs) "new activity" (Go "#notifications")
            ]
        , div [ class "home-columns" ]
            [ div [ class "card pad" ]
                [ div [ class "section-head" ]
                    [ h2 [] [ text "Recent DMs" ]
                    , button [ class "btn ghost", onClick NewDmModal ] [ text "New" ]
                    ]
                , div []
                    (if List.isEmpty recentConvs then
                        [ div [ class "empty" ] [ text "No direct messages yet." ] ]
                     else
                        List.map (\c -> convRow c model) recentConvs)
                ]
            , div [ class "card pad" ]
                [ div [ class "section-head" ] [ h2 [] [ text "Getting started" ] ]
                , ul [ class "check-list" ]
                    [ li [] [ text "Create or join a server." ]
                    , li [] [ text "Start a thread for longer conversations." ]
                    , li [] [ text "Message people directly." ]
                    ]
                ]
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
            , span [ class "forum-search-icon" ] [ text "🔍" ]
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
                [ span [ class "thread-action primary" ] [ text ("▣  " ++ String.fromInt t.replyCount ++ " replies") ]
                , span [ class "thread-action" ] [ text ("◉  " ++ String.fromInt t.views ++ " views") ]
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
    in div [ class "dm-inbox" ]
        [ div [ class "section-head" ]
            [ div []
                [ h2 [] [ text "Direct Messages" ]
                , p [ class "muted" ] [ text "Private chats and groups." ]
                ]
            , button [ class "btn", onClick NewDmModal ] [ text "New DM" ]
            ]
        , if List.isEmpty requests then text "" else
            div [ class "dm-request-section" ]
                [ h3 [ class "list-section-title" ] [ text ("Message requests · " ++ String.fromInt (List.length requests)) ]
                , div [ class "card dm-list-card" ] (List.map (messageRequestRow model) requests)
                ]
        , h3 [ class "list-section-title" ] [ text "Messages" ]
        , div [ class "card dm-list-card" ]
            (if List.isEmpty conversations then
                [ div [ class "empty dm-empty" ]
                    [ h2 [] [ text "No messages yet" ]
                    , p [] [ text "Start a conversation from Friends or New DM." ]
                    ]
                ]
             else
                List.map (\c -> convRow c model) conversations
            )
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
            [ div [] [ h3 [] [ text (heading ++ " — " ++ String.fromInt (List.length friends)) ], p [ class "muted" ] [ text description ] ] ]
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
            [ span [ class "add-friend-icon" ] [ text "+" ]
            , div []
                [ h3 [] [ text "Add Friend" ]
                , p [ class "muted" ] [ text "Find someone by their username or display name." ]
                ]
            ]
        , Html.form [ class "add-friend-form", onSubmit FindFriends ]
            [ span [ class "add-friend-search-icon", attribute "aria-hidden" "true" ] [ text "⌕" ]
            , input [ value model.friendQuery, onInput FriendQuery, placeholder "Search for a friend", attribute "aria-label" "Friend username", attribute "autocomplete" "off" ] []
            , button [ class "btn add-friend-submit", type_ "submit", disabled (String.length (String.trim model.friendQuery) < 2) ] [ text "Send Search" ]
            ]
        , if String.isEmpty (String.trim model.friendQuery) then
            div [ class "friend-discovery-hint" ]
                [ span [ class "discovery-art", attribute "aria-hidden" "true" ] [ text "☺" ]
                , b [] [ text "Friends make everything better" ]
                , p [] [ text "Search above to find people. You can use only part of their display name." ]
                ]
          else if List.isEmpty candidates && model.friendSearchAttempted then
            div [ class "friend-discovery-hint compact friend-not-found" ]
                [ b [] [ text "Can't find that user" ]
                , p [] [ text "Try again or check the spelling." ]
                ]
          else if List.isEmpty candidates then
            div [ class "friend-discovery-hint compact" ] [ b [] [ text "Ready to search" ], p [] [ text "Results will appear here after you press Send Search." ] ]
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
            div [ class "server-page" ]
                [ div [ class "card pad server-hero" ]
                    [ serverIcon data.server
                    , div []
                        [ h2 [] [ text data.server.name ]
                        , p [ class "muted" ] [ text (if String.isEmpty data.server.description then "No description yet." else data.server.description) ]
                , div [ class "nav-actions server-hero-actions" ]
                            [ button [ class "btn", onClick (InviteModal data.server.id) ] [ text "Invite people" ]
                            , button [ class "btn secondary", onClick (ChannelModal data.server.id) ] [ text "Add channel" ]
                            , button [ class "btn secondary", onClick (EditServerModal data.server) ] [ text "Customize" ]
                            ]
                        ]
                    ]
                , h3 [ class "server-section-title" ] [ text "Channels" ]
                , div [ class "card server-channel-card" ]
                    (channelGroup "Text channels" (List.filter (\c -> c.kind /= "voice") data.channels)
                     ++ channelGroup "Voice channels" (List.filter (\c -> c.kind == "voice") data.channels))
                , h3 [ class "server-section-title" ] [ text "Members" ]
                , div [ class "card" ] (List.map (\m -> memberRow model.userStatuses m) data.members)
                ]
        Nothing -> div [ class "empty" ] [ text "Loading server..." ]

channelRow : Channel -> Html Msg
channelRow c =
    let target = if c.kind == "voice" then "#voice/" else "#channel/"
        icon = if c.kind == "voice" then "♪" else "#"
    in a [ class "row", onClick (Go (target ++ String.fromInt c.id)) ]
        [ span [ class "server-icon" ] [ text icon ]
        , div [ class "grow" ] [ b [] [ text c.name ], small [ class "muted" ] [ text c.kind ] ]
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
                    , text (String.fromInt shareCount ++ " sharing screen — look for the floating window")
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

voiceParticipantRow : List ServerMember -> { userId : Int, muted : Bool, deafened : Bool, screen : Bool } -> Html Msg
voiceParticipantRow members vu =
    let maybeMember = List.filter (\m -> m.user.id == vu.userId) members |> List.head
        name = maybeMember |> Maybe.map (\m -> m.user.displayName) |> Maybe.withDefault ("User " ++ String.fromInt vu.userId)
        avatarUrl = maybeMember |> Maybe.map (\m -> m.user.avatarUrl) |> Maybe.withDefault ""
        stateText =
            if vu.screen then "Sharing screen"
            else if vu.deafened then "Deafened"
            else if vu.muted then "Muted"
            else "Live"
        pillClass =
            if vu.screen then "voice-state-pill sharing"
            else if vu.muted || vu.deafened then "voice-state-pill muted"
            else "voice-state-pill live"
        pillText =
            if vu.screen then "🖥 Share"
            else if vu.deafened then "🔇"
            else if vu.muted then "🔇 Muted"
            else "● Live"
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
                        Just "busy" -> "Busy"
                        Just _ -> "Online"
                        Nothing ->
                            let elapsed = agoAt model.serverTime u.lastSeen
                            in if elapsed == "never" then "Offline"
                               else if elapsed == "now" || elapsed == "1s" then "Last seen just now"
                               else "Last seen " ++ elapsed ++ " ago"
            in div [ class "card profile" ]
                [ div [ class "banner", style "background-image" (if String.isEmpty u.bannerUrl then "none" else "url('" ++ u.bannerUrl ++ "')") ] []
                , div [ class "profile-body" ]
                    [ presenceAvatar model.userStatuses u.id u.avatarUrl u.displayName "big"
                    , div []
                        [ h1 [] [ text u.displayName ]
                        , p [ class "muted profile-identity" ]
                            [ text ("@" ++ u.username ++ " · ")
                            , span [ class ("presence-text " ++ presence) ] [ text activityText ]
                            ]
                        , p [] [ text (if String.isEmpty u.bio then "No bio set." else u.bio) ]
                        , p [] [ span [ class ("pill presence-pill " ++ presence) ] [ span [ class ("status-dot " ++ presence) ] [], text activityText ] ]
                        , div [ class "nav-actions" ]
                            [ if viewingSelf then button [ class "btn", onClick (Go "#settings") ] [ text "Edit profile" ] else text ""
                            , if not viewingSelf && model.currentProfileRelationship /= "blocked" then button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int u.id)) ] [ text "Call" ] else text ""
                            , if not viewingSelf && model.currentProfileRelationship /= "blocked" then button [ class "btn secondary", onClick (BridgeEvent "dm_user" (E.int u.id)) ] [ text "Message" ] else text ""
                            , if not viewingSelf && model.currentProfileRelationship == "blocked" && model.currentProfileBlockedByMe then
                                button [ class "btn danger", onClick (BridgeEvent "unblock_user" (E.int u.id)) ] [ text "Unblock" ]
                              else if not viewingSelf && model.currentProfileRelationship == "blocked" then
                                button [ class "btn secondary", disabled True ] [ text "Unavailable" ]
                              else if not viewingSelf then
                                button [ class "btn danger", onClick (BridgeEvent "block_user" (E.int u.id)) ] [ text "Block" ]
                              else text ""
                            ]
                        ]
                    ]
                ]
        Nothing -> div [ class "empty" ] [ text "Loading profile..." ]

renderSettingsPage : Model -> Html Msg
renderSettingsPage model =
    case model.me of
        Just u ->
            div [ class "settings-page" ]
                [ aside [ class "settings-sidebar" ]
                    [ div [ class "settings-nav-label" ] [ text "User settings" ]
                    , a [ class ("settings-tab" ++ if model.settingsTab == "profile" then " active" else ""), onClick (SetSettingsTab "profile") ] [ span [ class "settings-tab-icon" ] [ text "●" ], text "Profile" ]
                    , a [ class ("settings-tab" ++ if model.settingsTab == "appearance" then " active" else ""), onClick (SetSettingsTab "appearance") ] [ span [ class "settings-tab-icon" ] [ text "◐" ], text "Appearance" ]
                    , a [ class ("settings-tab" ++ if model.settingsTab == "sound" then " active" else ""), onClick (SetSettingsTab "sound") ] [ span [ class "settings-tab-icon" ] [ text "◖" ], text "Notifications" ]
                    , div [ class "settings-nav-separator" ] []
                    , a [ class ("settings-tab" ++ if model.settingsTab == "account" then " active" else ""), onClick (SetSettingsTab "account") ] [ span [ class "settings-tab-icon" ] [ text "⚙" ], text "Account" ]
                    ]
                , div [ class "settings-content" ]
                    [ div [ class "settings-content-top" ]
                        [ div [] [ span [ class "eyebrow" ] [ text "Personal settings" ], h1 [] [ text (settingsTitle model.settingsTab) ] ]
                        , span [ class "settings-user-chip" ] [ avatarImg u.avatarUrl u.displayName "small", text ("@" ++ u.username) ]
                        ]
                    , div [ class "settings-content-inner" ]
                        [ case model.settingsTab of
                            "appearance" -> renderAppearanceSettings model
                            "sound" -> renderNotificationSettings model
                            "account" -> renderAccountSettings u
                            _ -> renderProfileSettings u model
                        ]
                    ]
                ]
        Nothing -> text ""

settingsTitle : String -> String
settingsTitle tab =
    case tab of
        "appearance" -> "Appearance"
        "sound" -> "Notifications"
        "account" -> "Account"
        _ -> "My Profile"

renderAccountSettings : User -> Html Msg
renderAccountSettings user =
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
        , div [ class "danger-zone" ]
            [ div []
                [ b [] [ text "Log out" ]
                , p [ class "muted" ] [ text "End this browser session." ]
                ]
            , button [ class "btn danger", onClick Logout ] [ text "Log out" ]
            ]
        ]

renderAppearanceSettings : Model -> Html Msg
renderAppearanceSettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Appearance" ], p [ class "muted" ] [ text "Make Plainwire feel comfortable on this device." ] ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Theme" ], small [ class "muted" ] [ text "Use your system colors or choose a theme." ] ]
            , select [ value model.profileTheme, onInput ProfileTheme ] [ option [ value "system" ] [ text "System" ], option [ value "light" ] [ text "Light" ], option [ value "dark" ] [ text "Dark" ] ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Interface density" ], small [ class "muted" ] [ text "Compact mode fits more channels and messages on screen." ] ]
            , div [ class "segmented-control" ]
                [ button [ class "btn secondary", onClick (BridgeEvent "ui_density" (E.string "comfortable")) ] [ text "Comfortable" ]
                , button [ class "btn secondary", onClick (BridgeEvent "ui_density" (E.string "compact")) ] [ text "Compact" ]
                ]
            ]
        , div [ class "setting-row setting-row-stack" ]
            [ div [] [ b [] [ text "Motion" ], small [ class "muted" ] [ text "Reduce interface animation when you prefer less movement." ] ]
            , div [ class "segmented-control" ]
                [ button [ class "btn secondary", onClick (BridgeEvent "reduce_motion" (E.bool False)) ] [ text "Standard" ]
                , button [ class "btn secondary", onClick (BridgeEvent "reduce_motion" (E.bool True)) ] [ text "Reduced" ]
                ]
            ]
        ]

renderNotificationSettings : Model -> Html Msg
renderNotificationSettings model =
    div [ class "settings-card settings-panel" ]
        [ div [ class "settings-card-head" ] [ h2 [] [ text "Notifications" ], p [ class "muted" ] [ text "Control alerts on this device." ] ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ span [ class "setting-icon" ] [ text "♫" ], div [] [ b [] [ text "Sound effects" ], small [ class "muted" ] [ text "Play sounds for messages, calls, and important activity." ] ] ]
            , button
                [ class ("settings-switch" ++ if model.soundEnabled then " active" else "")
                , onClick ToggleSound, attribute "role" "switch", attribute "aria-checked" (if model.soundEnabled then "true" else "false"), title "Toggle sound effects"
                ] [ span [ class "settings-switch-knob" ] [] ]
            ]
        , div [ class "setting-row" ]
            [ div [ class "setting-copy" ] [ span [ class "setting-icon" ] [ text "◉" ], div [] [ b [] [ text "Desktop notifications" ], small [ class "muted" ] [ text "Get alerts while Plainwire is open in the background." ] ] ]
            , button [ class "btn secondary settings-action", onClick (BridgeEvent "request_notifications" E.null) ] [ text "Review permission" ]
            ]
        ]

renderProfileSettings : User -> Model -> Html Msg
renderProfileSettings u model =
    div [ class "settings-card" ]
        [ div [ class "settings-banner", style "background-image" (if String.isEmpty model.profileBannerPreviewUrl then "linear-gradient(135deg, #5865f2, #232946)" else "url('" ++ model.profileBannerPreviewUrl ++ "')") ]
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
            , div [ class "file-upload-row" ]
                [ input [ id "profileAvatarFile", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "profileAvatarFile")) ] []
                , button [ class "btn secondary", onClick (ReadFile "profileAvatarFile"), disabled model.profileAvatarUploading ] [ text "Upload file" ]
                ]
            ]
        , div [ class "field" ]
            [ label [] [ text "Banner URL" ]
            , input [ value model.profileBannerUrl, placeholder "https://...", onInput ProfileBannerUrl ] []
            , div [ class "file-upload-row" ]
                [ input [ id "profileBannerFile", type_ "file", accept "image/jpeg,image/png,image/gif,image/webp,image/avif", on "change" (D.succeed (ReadFile "profileBannerFile")) ] []
                , button [ class "btn secondary", onClick (ReadFile "profileBannerFile"), disabled model.profileBannerUploading ] [ text "Upload file" ]
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
        , div [ class "field" ]
            [ label [] [ text "Theme" ]
            , select [ value model.profileTheme, onInput ProfileTheme ]
                [ option [ value "system" ] [ text "System" ]
                , option [ value "light" ] [ text "Light" ]
                , option [ value "dark" ] [ text "Dark" ]
                ]
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
    div [ class "card pad" ]
        [ div [ class "field" ] [ label [] [ text "Name" ], input [ value model.serverName, onInput ServerName ] [] ]
        , div [ class "field" ] [ label [] [ text "Description" ], textarea [ value model.serverDescription, onInput ServerDescription ] [] ]
        , button [ class "btn", onClick (CreateServer model.serverName model.serverDescription) ] [ text "Create" ]
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
    let callBar = case ( model.active, model.callUI.active ) of
            ( DmView convId, Just active ) ->
                if active.conversationId == convId then
                    [ renderDmCallBar active model ]
                else
                    []
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
                    let hasCall = case model.callUI.active of
                            Just a -> a.conversationId == id
                            Nothing -> False
                        joinedCall = isJoinedCall id model
                    in div [ class "chat-header" ]
                        [ convAvatar model c
                        , div [ class "grow" ]
                            [ h2 [] [ text (convName c) ]
                            , small [ class "muted" ] [ text (if c.memberCount > 2 then String.fromInt c.memberCount ++ " people" else "Direct message") ]
                            ]
                        , if joinedCall then
                            button [ class "btn call-decline", onClick EndCall ] [ text "Leave Call" ]
                          else if hasCall then
                            button [ class "btn call-accept", onClick (JoinCall id) ] [ text "Join Call" ]
                          else
                            button [ class "btn", onClick (BridgeEvent "start_call" (E.int id)) ] [ text "Call" ]
                        ]
                [] -> chatOnlineHeader
        ChannelView _ -> chatOnlineHeader
        _ -> chatOnlineHeader

isJoinedCall : Int -> Model -> Bool
isJoinedCall conversationId model =
    model.voice.mode == Just "call" && model.voice.id == Just conversationId

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
            [ span [ class "dm-call-bar-icon" ] [ text "♪" ]
            , span [ class "dm-call-bar-title" ] [ text (if joinedCall then "In Call" else "Call active") ]
            , span [ class "dm-call-bar-timer" ] [ text (if joinedCall then minutes ++ ":" ++ seconds else "Ready to join") ]
            , span [ class "dm-call-bar-count" ] [ text countText ]
            ]
        , div [ class "dm-call-bar-controls" ]
            (if joinedCall then
                [ button [ class ("btn icon-btn" ++ if model.voice.muted then " call-muted" else ""), onClick (BridgeEvent "toggle_mute" E.null) ]
                    [ text (if model.voice.muted then "🔇" else "🎤") ]
                , button [ class ("btn icon-btn" ++ if model.voice.deafened then " call-muted" else ""), onClick (BridgeEvent "toggle_deafen" E.null) ]
                    [ text (if model.voice.deafened then "🔇" else "🔊") ]
                , button [ class "btn icon-btn", onClick (BridgeEvent "toggle_speaker" E.null) ]
                    [ text "🔈" ]
                , button [ class "btn call-decline", onClick EndCall ]
                    [ text "✕ Leave" ]
                ]
             else
                [ button [ class "btn call-accept", onClick (JoinCall active.conversationId) ] [ text "Join Call" ] ]
            )
        ]

chatOnlineHeader : Html Msg
chatOnlineHeader =
    div [ class "chat-status" ]
        [ span [ class "live-dot" ] []
        , span [] [ text "Online" ]
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
        , textarea [ id "compose", placeholder placeholderText, value model.inputText, onInput InputText, onComposerKeyDown ] []
        , div [ class "composer-footer" ]
            [ button [ class "btn secondary attach-btn", type_ "button", title "Attach files or images", onClick (BridgeEvent "pick_attachments" E.null) ] [ text "＋ Attach" ]
            , small [ class "muted" ] [ text "Paste images or attach files up to 250 MB." ]
            , button [ class "btn", disabled (String.isEmpty (String.trim model.inputText)), onClick SendMessage ] [ text "Send" ]
            ]
        ]

renderMessageBody : String -> List (Html Msg)
renderMessageBody body =
    let lines = String.lines body
    in lines
        |> List.indexedMap (\index line ->
            case attachmentMarkup line of
                Just ( True, name, url ) ->
                    a [ class "message-image-link", href url, target "_blank", rel "noopener" ]
                        [ img [ class "message-image", src url, alt name, attribute "loading" "lazy" ] [] ]
                Just ( False, name, url ) ->
                    a [ class "message-file", href url, target "_blank", rel "noopener" ]
                        [ span [ class "message-file-icon" ] [ text "↧" ], span [] [ text name ] ]
                Nothing ->
                    if String.startsWith "https://" line || String.startsWith "http://" line then
                        a [ class "message-link", href line, target "_blank", rel "noopener noreferrer" ] [ text line ]
                    else
                        span [] [ text line, if index < List.length lines - 1 then br [] [] else text "" ]
        )

attachmentMarkup : String -> Maybe ( Bool, String, String )
attachmentMarkup line =
    let
        parse image prefix endpoint =
            if String.startsWith prefix line && String.endsWith ")" line then
                case String.split ("](" ++ endpoint) line of
                    [ left, idPart ] ->
                        let name = String.dropLeft (String.length prefix) left
                            ident = String.dropRight 1 idPart
                        in if String.isEmpty name || String.isEmpty ident || String.contains "/" ident then Nothing
                           else Just ( image, name, endpoint ++ ident )
                    _ -> Nothing
            else Nothing
    in case parse True "![" "/api/files/" of
        Just value -> Just value
        Nothing ->
            case parse True "![" "/api/media/" of
                Just value -> Just value
                Nothing -> parse False "[" "/api/files/"

onComposerKeyDown : Attribute Msg
onComposerKeyDown =
    custom "keydown"
        (D.map2
            (\key shift ->
                if key == "Enter" && not shift then
                    { message = SendMessage, stopPropagation = True, preventDefault = True }
                else
                    { message = NoOp, stopPropagation = False, preventDefault = False }
            )
            (D.field "key" D.string)
            (D.field "shiftKey" D.bool)
        )

renderNotificationsPage : Model -> Html Msg
renderNotificationsPage model =
    div [ class "notifications-page" ]
        [ div [ class "section-head notifications-head" ]
            [ div [] [ h2 [] [ text "Notifications" ], p [ class "muted" ] [ text "Mentions, replies, requests, and messages." ] ]
            , div [ class "nav-actions" ]
                [ button [ class "btn secondary", onClick ClearNotifs, disabled (List.isEmpty model.notifs) ] [ text "Clear all" ] ]
            ]
        , div [ class "card notifications-list" ]
            (if List.isEmpty model.notifs then
                [ div [ class "empty" ] [ text "No notifications." ] ]
             else
                List.map (notificationView model.serverTime) model.notifs
            )
        ]

notificationView : Int -> Notification -> Html Msg
notificationView now n =
    a [ class ("row notif" ++ if n.seen then "" else " unseen"), onClick (Go n.url) ]
        [ div [ class "grow" ]
            [ b [] [ text n.kind ]
            , small [] [ text n.body ]
            ]
        , span [ class "muted notif-time" ] [ text (relativeTime now n.createdAt) ]
        ]

relativeTime : Int -> Int -> String
relativeTime now timestamp =
    let elapsed = agoAt now timestamp
    in if elapsed == "now" || elapsed == "1s" then "just now"
       else if elapsed == "never" then ""
       else elapsed ++ " ago"

renderSearchPage : String -> Model -> Html Msg
renderSearchPage q model =
    div []
        [ h3 [] [ text ("Users matching " ++ q) ]
        , div [ class "card" ]
            (if List.isEmpty model.searchUsers then
                [ div [ class "empty" ] [ text "No users." ] ]
             else
                List.map searchUserView model.searchUsers
            )
        , h3 [] [ text "Threads" ]
        , div [ class "card" ]
            (if List.isEmpty model.searchThreads then
                [ div [ class "empty" ] [ text "No threads." ] ]
             else
                List.map searchThreadView model.searchThreads
            )
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
        "invalid_registration" -> "Username must be 3-24 characters and password must be at least 8 characters."
        "username_taken" -> "That username is already taken."
        "server_exists" -> "You already have a server with that name."
        "channel_exists" -> "A channel with that name already exists in this server."
        "invalid_server_name" -> "Server name must be at least 2 characters."
        "invalid_channel_name" -> "Channel name is required."
        "invalid_channel" -> "That invite channel does not belong to this server."
        "invalid_invite" -> "That invite is invalid, expired, or has been revoked."
        "bad_login" -> "Username or password is incorrect."
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
    else if model.authMode == "register" && String.length password < 8 then
        Just "Password must be at least 8 characters."
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
        ]


-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ onHashChange SetRoute
        , apiReceive decodeApi
        , wsReceive WsEvent
        , bridgeReceive decodeBridge
        , fileInput decodeFileInput
        , Browser.Events.onVisibilityChange (\_ -> NoOp)
        , Time.every 3000 Tick
        ]
