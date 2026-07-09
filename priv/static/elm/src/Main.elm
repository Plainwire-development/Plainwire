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
    | BtHashChange String
    | BtTick

decodeBridge : E.Value -> Msg
decodeBridge val = case D.decodeValue bridgeDecoder val of
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
        "tick" -> D.succeed (Tick (Time.millisToPosix 0))
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
      , servers = [], convs = [], friends = [], notifs = []
      , searchUsers = [], searchThreads = []
      , currentServer = Nothing, currentProfile = Nothing, invitePreview = Nothing
      , msg = [], nextBefore = Nothing
      , active = active, serverCache = Dict.empty
      , drafts = Dict.empty, wsConnected = False, isLeader = False
      , tabId = "", subs = Set.empty
      , voice = { mode = Nothing, id = Nothing, stream = Nothing
                , peers = Dict.empty, users = Dict.empty
                , muted = False, deafened = False }
      , callUI = { incoming = Nothing, outgoing = Nothing }
      , callMode = Idle, soundEnabled = True, replyTo = Nothing
      , toast = Nothing, modal = Nothing, settingsTab = "profile"
      , inputText = "", sidebarOpen = False, ctxMenu = Nothing
      , threadReply = "", searchQuery = ""
      , authMode = "login", authUsername = "", authBusy = False, authDisplayName = ""
      , authPassword = "", serverName = "", serverDescription = "", booting = True
      , profileDisplayName = "", profileBio = ""
      , profileAvatarUrl = "", profileBannerUrl = ""
      , profileStatus = "online", profileTheme = "system"
      , modalTitle = "", modalBody = "", modalUserIds = ""
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
            in ( { model | active = active
                  , msg = [], sidebarOpen = False
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

        ApiSuccess tag val ->
            case tag of
                "/me" -> handleMe val model
                "/login" -> handleMe val model
                "/register" -> handleMe val model
                "/sync?since=0" -> handleSync val model
                "/forums" -> handleList (D.list decodeForum) (\items m -> { m | forums = items }) val model
                "/logout" -> ( model, bridgeSend (E.object [("tag", E.string "reload"), ("data", E.null)]) )
                "/profile" -> ( { model | toast = Just "Profile saved" }, apiSend (encodeApiRequest (ApiGet "/me")) )
                "/notifications/seen" -> ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                "/friends/request" -> ( { model | toast = Just "Friend request sent" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                "/friends/accept" -> ( { model | toast = Just "Friend added" }, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                "/friends/remove" -> ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                "/friends/block" -> ( model, apiSend (encodeApiRequest (ApiGet "/sync?since=0")) )
                "/conversations" -> handleCreateConversation val model
                "/threads" -> handleCreateThread val model
                _ ->
                    if String.startsWith "/threads?forum_id=" tag then
                        handleList (D.list decodeThread) (\items m -> { m | threads = items }) val model
                    else if String.startsWith "/thread/" tag && String.endsWith "/replies" tag then
                        handleReplyCreated val model
                    else if String.startsWith "/thread/" tag then
                        handleThread val model
                    else if String.startsWith "/messages?" tag then
                        handleMessages val model
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

        ApiError tag err ->
            if err == "not_authenticated" && model.me == Nothing then
                ( { model | booting = False }, Cmd.none )
            else
                ( { model | booting = False, authBusy = False, toast = Just (fmtErr err) }, Cmd.none )

        WsEvent val -> handleWsEvent val model

        Go hash -> ( model, setHash hash )

        ToggleSidebar -> ( { model | sidebarOpen = not model.sidebarOpen }, Cmd.none )
        CloseSidebar -> ( { model | sidebarOpen = False }, Cmd.none )

        Toast s -> ( { model | toast = Just s }, Cmd.none )
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

        DeleteMessage mid ->
            ( { model | ctxMenu = Nothing }, apiSend (encodeApiRequest (ApiPost ("/delete_message/" ++ String.fromInt mid) (Just (E.object [])))) )

        LeaveConversation cid ->
            ( { model | ctxMenu = Nothing }, Cmd.batch [ apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/leave") (Just (E.object [])))), setHash "#dms" ] )

        MarkConvRead cid -> ( model, apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt cid ++ "/read") (Just (E.object [])))) )
        OpenMessageCtx m x y -> ( { model | ctxMenu = Just (messageContext model.me m x y) }, Cmd.none )
        OpenConvCtx c x y -> ( { model | ctxMenu = Just (conversationContext c x y) }, Cmd.none )
        CopyText s -> ( { model | ctxMenu = Nothing }, copyText s )

        SilentSync _ ->
            ( model
            , if model.me == Nothing then Cmd.none else apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
            )

        Tick now ->
            ( { model | serverTime = Time.posixToMillis now }
            , if model.me == Nothing then
                Cmd.none
              else
                Cmd.batch
                    [ apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                    , routeCmd model.active
                    ]
            )

        ToggleSound -> ( { model | soundEnabled = not model.soundEnabled }
                       , if not model.soundEnabled then playNotification True else Cmd.none )

        Logout -> ( model, apiSend (encodeApiRequest (ApiPost "/logout" (Just (E.object [])))) )

        SetSettingsTab t -> ( { model | settingsTab = t }, Cmd.none )

        ProfileDisplayName s -> ( { model | profileDisplayName = s }, Cmd.none )
        ProfileBio s -> ( { model | profileBio = s }, Cmd.none )
        ProfileAvatarUrl s -> ( { model | profileAvatarUrl = s }, Cmd.none )
        ProfileBannerUrl s -> ( { model | profileBannerUrl = s }, Cmd.none )
        ProfileStatus s -> ( { model | profileStatus = s }, Cmd.none )
        ProfileTheme s -> ( { model | profileTheme = s }, Cmd.none )

        SaveProfile ->
            ( model
            , apiSend (encodeApiRequest (ApiPost "/profile" (Just (E.object
                [ ("display_name", E.string model.profileDisplayName)
                , ("bio", E.string model.profileBio)
                , ("avatar_url", E.string model.profileAvatarUrl)
                , ("banner_url", E.string model.profileBannerUrl)
                , ("status", E.string model.profileStatus)
                , ("theme", E.string model.profileTheme)
                ]))))
            )

        SearchQuery q -> ( { model | searchQuery = q }, Cmd.none )

        DoSearch -> ( model, setHash ("#search/" ++ model.searchQuery) )

        ClearNotifs -> ( model, apiSend (encodeApiRequest (ApiPost "/notifications/seen" (Just (E.object [])))) )

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
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing }, callMode = Connected, voice = updateVoiceMode "call" conversationId model.voice }
            , Cmd.batch
                [ bridgeSend (E.object [("tag", E.string "accept_call"), ("data", E.int conversationId)])
                , playRingtone False
                ]
            )

        DeclineCall conversationId ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing }, callMode = Idle }
            , Cmd.batch
                [ bridgeSend (E.object [("tag", E.string "decline_call"), ("data", E.int conversationId)])
                , playRingtone False
                , playOutgoingRingtone False
                ]
            )

        EndCall ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing }, callMode = Idle, voice = clearVoice model.voice }
            , bridgeSend (E.object [("tag", E.string "end_call"), ("data", E.null)])
            )

        NewThreadModal maybeForumId ->
            ( { model | modal = Just ("new_thread:" ++ maybeIntString maybeForumId), modalTitle = "", modalBody = "", modalUserIds = maybeIntString maybeForumId }, Cmd.none )

        NewDmModal ->
            ( { model | modal = Just "new_dm", modalTitle = "", modalUserIds = "" }, Cmd.none )

        SearchUsersModal ->
            ( { model | modal = Just "search", searchQuery = "" }, Cmd.none )

        ModalTitle s -> ( { model | modalTitle = s }, Cmd.none )
        ModalBody s -> ( { model | modalBody = s }, Cmd.none )
        ModalUserIds s -> ( { model | modalUserIds = s }, Cmd.none )
        SubmitModal -> submitModal model

        InviteModal serverId ->
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
                "leave_voice" ->
                    ( { model | voice = clearVoice model.voice, callMode = Idle }, cmd )
                "toggle_mute" ->
                    ( { model | voice = toggleMute model.voice }, bridgeSend (E.object [("tag", E.string "voice_mute"), ("data", E.bool (not model.voice.muted))]) )
                "toggle_deafen" ->
                    ( { model | voice = toggleDeafen model.voice }, bridgeSend (E.object [("tag", E.string "voice_deafen"), ("data", E.bool (not model.voice.deafened))]) )
                _ ->
                    ( model, cmd )

        CloseCtx ->
            ( { model | ctxMenu = Nothing }, Cmd.none )

        CtxAction idx ->
            case model.ctxMenu |> Maybe.andThen (\menu -> listAt idx menu.items) of
                Just item -> update item.msg { model | ctxMenu = Nothing }
                Nothing -> ( { model | ctxMenu = Nothing }, Cmd.none )

        _ -> ( model, Cmd.none )


handleMe : E.Value -> Model -> ( Model, Cmd Msg )
handleMe val model =
    case D.decodeValue decodeUser (fromApiField "user" val) of
                    Ok user -> ( { model | me = Just user
                                    , csrf = fromApiFieldStr "csrf" val
                                    , serverTime = fromApiFieldInt "server_time" val
                                    , booting = False
                                    , authBusy = False
                                    , profileDisplayName = user.displayName
                                    , profileBio = user.bio
                                    , profileAvatarUrl = user.avatarUrl
                                    , profileBannerUrl = user.bannerUrl
                                    , profileStatus = statusToString user.status
                                    , profileTheme = user.theme
                                    }
                                , Cmd.batch
                                    [ bridgeSend (E.object [("tag", E.string "connect_ws"), ("data", E.null)])
                                    , apiSend (encodeApiRequest (ApiGet "/sync?since=0"))
                                    , routeCmd model.active
                                    ]
                                )
                    Err _ -> ( model, Cmd.none )


handleSync : E.Value -> Model -> ( Model, Cmd Msg )
handleSync val model =
    case D.decodeValue decodeSyncData val of
        Ok data ->
            ( { model
                | notifs = data.notifications
                , convs = sortConvs data.conversations
                , servers = data.servers
                , friends = data.friends
                , serverTime = data.now
              }
            , Cmd.none
            )
        Err _ -> ( model, Cmd.none )


handleList : Decoder (List a) -> (List a -> Model -> Model) -> E.Value -> Model -> ( Model, Cmd Msg )
handleList decoder apply val model =
    case D.decodeValue decoder val of
        Ok items -> ( apply items model, Cmd.none )
        Err _ -> ( model, Cmd.none )


handleMessages : E.Value -> Model -> ( Model, Cmd Msg )
handleMessages val model =
    case D.decodeValue (D.list decodeMessage) val of
        Ok items ->
            let cmd = case model.active of
                    DmView id ->
                        if String.isEmpty model.csrf then Cmd.none
                        else apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt id ++ "/read") (Just (E.object []))))
                    _ -> Cmd.none
            in ( { model | msg = List.reverse items }, cmd )
        Err err ->
            ( { model | toast = Just ("Could not load messages: " ++ D.errorToString err) }, Cmd.none )


handleThread : E.Value -> Model -> ( Model, Cmd Msg )
handleThread val model =
    case D.decodeValue threadDetailDecoder val of
        Ok detail -> ( { model | currentThread = Just detail.thread, replies = detail.replies }, Cmd.none )
        Err _ -> ( model, Cmd.none )


handleMessageSent : E.Value -> Model -> ( Model, Cmd Msg )
handleMessageSent val model =
    case D.decodeValue decodeMessage val of
        Ok message ->
            ( { model | msg = List.filter (\m -> m.id > 0) model.msg ++ [ message ], inputText = "", replyTo = Nothing }
            , Cmd.batch [ apiSend (encodeApiRequest (ApiGet "/sync?since=0")), routeCmd model.active ]
            )
        Err err ->
            ( { model | inputText = "", replyTo = Nothing, toast = Just ("Message sent, but could not display it yet: " ++ D.errorToString err) }, routeCmd model.active )


handleCreateConversation : E.Value -> Model -> ( Model, Cmd Msg )
handleCreateConversation val model =
    case D.decodeValue (D.field "id" D.int) val of
        Ok id ->
            ( model
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
            else if kind == "new_dm" then
                let ids = csvInts model.modalUserIds in
                if List.isEmpty ids then
                    ( { model | toast = Just "Add at least one user" }, Cmd.none )
                else
                    ( { model | modal = Nothing }
                    , apiSend (encodeApiRequest (ApiPost "/conversations" (Just (E.object
                        [ ("user_ids", E.list E.int ids)
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
    case D.decodeValue (D.field "url" D.string) val of
        Ok url ->
            ( { model | toast = Just "Invite copied" }
            , Cmd.batch [ copyText ("/" ++ url), routeCmd model.active ]
            )
        Err _ ->
            ( { model | toast = Just "Invite created" }, routeCmd model.active )


serverDataDecoder : Decoder ServerData
serverDataDecoder =
    D.map3 (\server channels members -> { server = server, channels = channels, members = members })
        (D.field "server" decodeServer)
        (D.field "channels" (D.list decodeChannel))
        (D.field "members" (D.list decodeServerMember))


handleProfile : E.Value -> Model -> ( Model, Cmd Msg )
handleProfile val model =
    case D.decodeValue (D.field "user" decodeUser) val of
        Ok user -> ( { model | currentProfile = Just user }, Cmd.none )
        Err _ -> ( model, Cmd.none )


handleInvitePreview : E.Value -> Model -> ( Model, Cmd Msg )
handleInvitePreview val model =
    case D.decodeValue invitePreviewDecoder val of
        Ok invite -> ( { model | invitePreview = Just invite }, Cmd.none )
        Err _ -> ( model, Cmd.none )


invitePreviewDecoder : Decoder InvitePreview
invitePreviewDecoder =
    D.map8 InvitePreview
        (D.field "code" D.string)
        (D.field "server_id" D.int)
        (D.field "channel_id" (D.nullable D.int))
        (D.field "valid" D.bool)
        (D.at [ "server", "name" ] D.string)
        (D.at [ "server", "description" ] D.string)
        (D.at [ "server", "icon_url" ] D.string)
        (D.at [ "server", "member_count" ] D.int)


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
        DmView id -> apiSend (encodeApiRequest (ApiGet ("/messages?scope=direct&scope_id=" ++ String.fromInt id)))
        ChannelView id -> apiSend (encodeApiRequest (ApiGet ("/messages?scope=channel&scope_id=" ++ String.fromInt id)))
        ServerView id -> apiSend (encodeApiRequest (ApiGet ("/server/" ++ String.fromInt id)))
        ProfileView id -> apiSend (encodeApiRequest (ApiGet ("/profile/" ++ String.fromInt id)))
        InviteView code -> apiSend (encodeApiRequest (ApiGet ("/invites/" ++ code)))
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
    { voice | mode = Nothing, id = Nothing }


toggleMute : VoiceState -> VoiceState
toggleMute voice =
    { voice | muted = not voice.muted }


toggleDeafen : VoiceState -> VoiceState
toggleDeafen voice =
    { voice | deafened = not voice.deafened }


sendMessage : Model -> ( Model, Cmd Msg )
sendMessage model =
    let body = String.trim model.inputText
        replyField = Maybe.map .id model.replyTo
        payload = encodeMessage { body = body, replyToId = replyField }
    in
    if String.isEmpty body then
        ( model, Cmd.none )
    else
        case model.active of
            DmView id ->
                ( appendOptimisticMessage "direct" id body model
                , apiSend (encodeApiRequest (ApiPost ("/conversation/" ++ String.fromInt id ++ "/messages") (Just payload)))
                )
            ChannelView id ->
                ( appendOptimisticMessage "channel" id body model
                , apiSend (encodeApiRequest (ApiPost ("/channels/" ++ String.fromInt id ++ "/messages") (Just payload)))
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
            ( { model | callUI = { incoming = Nothing, outgoing = model.callUI.outgoing }, callMode = Ringing }, Cmd.none )
        Ok ( "call_accepted", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing }, callMode = Connected }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
        Ok ( "call_declined", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing }, callMode = Idle }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
        Ok ( "call_cancelled", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing }, callMode = Idle }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
        Ok ( "call_ended", _ ) ->
            ( { model | callUI = { incoming = Nothing, outgoing = Nothing }, callMode = Idle, voice = clearVoice model.voice }, Cmd.batch [ playRingtone False, playOutgoingRingtone False ] )
        Ok ( "call_state", ev ) -> ( model, Cmd.none )
        Ok ( "call_peer_joined", ev ) -> ( model, Cmd.none )
        Ok ( "call_peer_left", ev ) -> ( model, Cmd.none )
        Ok ( "call_signal", ev ) -> ( model, Cmd.none )
        Ok ( "voice_state", ev ) -> ( model, Cmd.none )
        Ok ( "voice_user_joined", ev ) -> ( model, Cmd.none )
        Ok ( "voice_user_left", ev ) -> ( model, Cmd.none )
        Ok ( "voice_signal", ev ) -> ( model, Cmd.none )
        Ok ( "error", ev ) ->
            ( model
            , bridgeSend (E.object
                [ ("tag", E.string "toast")
                , ("data", E.string "error")
                ])
            )
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
                ( { model | msg = model.msg ++ [ message ] }, playNotification model.soundEnabled )
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
                , outgoing = Nothing }
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
        (D.field "user_id" D.int)
        (D.oneOf [ D.field "display_name" D.string, D.succeed "Unknown" ])
        (D.oneOf [ D.field "avatar_url" D.string, D.succeed "" ])


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
    Just msg -> div [ class "toast", onClick DismissToast ] [ text msg ]
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
            , div [ class "field" ] [ label [] [ text "Body" ], textarea [ value model.modalBody, placeholder "Write the first post...", onInput ModalBody ] [] ]
            ]
        , modalActions "Create thread"
        ]
    else if kind == "new_dm" then
        [ modalHead "New message" "Start a DM or group chat." 
        , div [ class "modal-body" ]
            [ div [ class "field" ] [ label [] [ text "User IDs" ], input [ value model.modalUserIds, placeholder "Example: 2 or 2, 5, 9", onInput ModalUserIds ] [] ]
            , div [ class "field" ] [ label [] [ text "Group name optional" ], input [ value model.modalTitle, placeholder "Leave blank for a 1:1 DM", onInput ModalTitle ] [] ]
            , p [ class "muted modal-hint" ] [ text "Tip: use Search to find a person, then press Message." ]
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
        mineItems = if mine then [ { label = "Delete message", icon = Just "×", danger = True, sep = True, msg = DeleteMessage message.id } ] else []
    in { items = base ++ mineItems, x = x, y = y }

conversationContext : Conversation -> Int -> Int -> ContextMenu
conversationContext c x y =
    let closeItem =
            if c.memberCount > 2 then
                { label = "Leave group", icon = Just "×", danger = True, sep = True, msg = LeaveConversation c.id }
            else
                { label = "Close", icon = Just "×", danger = False, sep = True, msg = Go "#dms" }
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

renderCallLayer : Model -> Html Msg
renderCallLayer model =
    let popups = List.filterMap identity
            [ Maybe.map (\i -> renderCallPopup "incoming" i model) model.callUI.incoming
            , Maybe.map (\o -> renderCallPopup "outgoing" o model) model.callUI.outgoing
            ]
        activeDock = case model.callMode of
            Connected -> [ renderActiveCallDock model ]
            InCall -> [ renderActiveCallDock model ]
            _ -> []
    in div [ class "call-layer" ] (popups ++ activeDock)

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
                    [ button [ class "btn call-decline", onClick (DeclineCall popup.conversationId) ] [ text "Cancel" ]
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

renderActiveCallDock : Model -> Html Msg
renderActiveCallDock model =
    div [ class "call-popup active-call" ]
        [ div [ class "call-popup-head" ]
            [ div [ class "call-avatar-wrap" ]
                [ div [ class "avatar big" ] [ text "♪" ]
                , span [ class "call-status-dot live" ] []
                ]
            , div []
                [ p [ class "call-popup-title" ] [ text "Voice connected" ]
                , p [ class "call-popup-sub" ] [ text (if model.voice.deafened then "Deafened" else if model.voice.muted then "Muted" else "Live audio") ]
                , div [ class "call-wave" ] [ span [] [], span [] [], span [] [], span [] [], span [] [] ]
                ]
            ]
        , div [ class "call-popup-controls" ]
            [ button [ class "btn secondary", onClick (BridgeEvent "toggle_mute" E.null) ] [ text (if model.voice.muted then "Unmute" else "Mute") ]
            , button [ class "btn secondary", onClick (BridgeEvent "toggle_deafen" E.null) ] [ text (if model.voice.deafened then "Undeafen" else "Deafen") ]
            , button [ class "btn call-decline", onClick EndCall ] [ text "Disconnect" ]
            ]
        ]


avatarImg : String -> String -> String -> Html Msg
avatarImg url name cls =
    if String.isEmpty url then
        div [ class ("avatar " ++ cls) ]
            [ text (String.left 1 (String.toUpper name)) ]
    else
        img [ class ("avatar " ++ cls), src url, alt "" ] []


-- AUTH VIEW

renderAuth : Model -> Html Msg
renderAuth model =
    div [ class "layout" ]
        [ div [] []
        , main_ [ class "main" ]
            [ div [ class "content" ]
                [ div [ class "card pad", style "max-width" "520px", style "margin" "8vh auto" ]
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
            , div [ class "content" ] [ renderPage model ]
            ]
        , renderRightPanel model
        , div [ class ("drawer-overlay" ++ if model.sidebarOpen then " open" else "")
              , onClick CloseSidebar
              ] []
        , renderMobileNav model
        , renderContextMenu model
        , renderModal model
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
        img [ class "server-icon", src s.iconUrl, alt "" ] []


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
             ++ List.map (\c -> convRow c model) model.convs)
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
        , div [ class "list" ] (List.map channelRow data.channels)
        , userPanel model
        ]

renderRightPanel : Model -> Html Msg
renderRightPanel model =
    case ( model.active, model.currentServer ) of
        ( ServerView _, Just data ) -> renderMembersPanel data.members
        ( ChannelView _, Just data ) -> renderMembersPanel data.members
        ( VoiceChannelView _, Just data ) -> renderMembersPanel data.members
        _ -> text ""

renderMembersPanel : List ServerMember -> Html Msg
renderMembersPanel members =
    aside [ class "right members-panel" ]
        [ h3 [] [ text "Members" ]
        , div [ class "list" ] (List.map memberRow members)
        ]

sideHead : Model -> Html Msg
sideHead model =
    div [ class "side-head" ]
        [ h1 [] [ text "Plainwire" ]
        , small [] [ text "Chat app" ]
        , div [ class "nav-actions" ]
            [ button [ class "btn secondary", onClick (Go "#new-server") ] [ text "New server" ]
            , button [ class "btn secondary", onClick JoinInvite ] [ text "Use invite" ]
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
friendsRow _ =
    a [ class "row", onClick (Go "#friends") ]
        [ span [ class "server-icon" ] [ text "+" ]
        , div [ class "grow" ]
            [ b [] [ text "Friends" ], small [ class "muted" ] [ text "requests and contacts" ] ]
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
        [ convAvatar c
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

convAvatar : Conversation -> Html Msg
convAvatar c =
    if not (String.isEmpty c.avatarUrl) then
        img [ class "avatar", src c.avatarUrl, alt "" ] []
    else if c.memberCount == 2 then
        avatarImg c.peerAvatarUrl (convName c) ""
    else
        div [ class "avatar group-avatar" ] [ text (String.fromInt c.memberCount) ]

userPanel : Model -> Html Msg
userPanel model = case model.me of
    Just u ->
        div [ class "user-panel" ]
            [ avatarImg u.avatarUrl u.displayName ""
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
        , mobileBtn "#" "Forums" (model.active == Forums) (Go "#forums")
        , mobileBtn "D" "DMs" (isDmActive model) (Go "#dms")
        , mobileBtn "+" "Friends" (model.active == Friends) (Go "#friends")
        , mobileBtn "⚙" "You" (model.active == Settings) (Go "#settings")
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
    InviteView code -> renderInvitePage model
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
    div [ class "forum-page" ]
        [ div [ class "section-head" ]
            [ div [] [ h2 [] [ text "Threads" ], p [ class "muted" ] [ text "Longer conversations by topic." ] ]
            , button [ class "btn", onClick (NewThreadModal Nothing) ] [ text "New thread" ]
            ]
        , div [ class "grid" ] (List.map forumCard model.forums)
        ]

forumCard : Forum -> Html Msg
forumCard f =
    div [ class "card pad", onClick (Go ("#forum/" ++ String.fromInt f.id)) ]
        [ div [ class "forum-card-head" ]
            [ span [ class "forum-glyph" ] [ text "r/" ]
            , h2 [] [ text f.name ]
            ]
        , p [ class "muted" ] [ text f.description ]
        , div [ class "forum-stats" ]
            [ span [ class "pill" ] [ text (String.fromInt f.threadCount ++ " threads") ]
            , span [ class "pill" ] [ text (String.fromInt f.replyCount ++ " replies") ]
            , span [ class "pill" ] [ text ("last " ++ Maybe.withDefault "never" (Maybe.map ago f.lastAt)) ]
            ]
        ]

renderForumPage : Int -> Model -> Html Msg
renderForumPage id model =
    div [ class "forum-page" ]
        [ div [ class "section-head" ]
            [ div [] [ h2 [] [ text "Threads" ], p [ class "muted" ] [ text "Pick a topic and jump in." ] ]
            , button [ class "btn", onClick (NewThreadModal (Just id)) ] [ text "New thread" ]
            ]
        , div [ class "thread-listing" ]
            (List.map threadRow model.threads
                |> (\l -> if List.isEmpty l then [ div [ class "empty" ] [ text "No threads yet." ] ] else l)
            )
        ]

threadRow : ForumThread -> Html Msg
threadRow t =
    div [ class "reddit-thread", onClick (Go ("#thread/" ++ String.fromInt t.id)) ]
        [ div [ class "vote-column" ]
            [ button [ class "vote-btn up" ] [ text "▲" ]
            , span [ class "vote-count" ] [ text (String.fromInt t.replyCount) ]
            , button [ class "vote-btn down" ] [ text "▼" ]
            ]
        , div [ class "thread-content" ]
            [ h3 [ class "thread-title" ]
                ((if t.pinned then [ span [ class "pill pin" ] [ text "pinned" ], text " " ] else [])
                 ++ (if t.replyCount > 10 then [ span [ class "pill hot" ] [ text "hot" ], text " " ] else [])
                 ++ [ text t.title ])
            , div [ class "thread-meta" ]
                [ span [] [ text t.displayName ]
                , span [] [ text (String.fromInt t.replyCount ++ " replies") ]
                , span [] [ text (String.fromInt t.views ++ " views") ]
                , span [] [ text (ago t.updatedAt) ]
                ]
            ]
        ]

renderThreadPage : Int -> Model -> Html Msg
renderThreadPage threadId model =
    case model.currentThread of
        Just t ->
            div []
                [ div [ class "post card reddit-post" ]
                    [ div [ class "vote-column" ]
                        [ button [ class "vote-btn up" ] [ text "▲" ]
                        , span [ class "vote-count" ] [ text (String.fromInt t.replyCount) ]
                        , button [ class "vote-btn down" ] [ text "▼" ]
                        ]
                    , div [ class "post-body" ]
                        [ h1 [ class "thread-title" ] [ text t.title ]
                        , div [ class "post-meta" ]
                            [ avatarImg "" t.displayName ""
                            , b [] [ text t.displayName ]
                            , span [ class "muted" ] [ text (ago t.createdAt ++ " ago") ]
                            ]
                        , div [ class "msg-body" ] [ text t.body ]
                        ]
                    ]
                , div [ id "replies" ] (List.map replyView model.replies)
                , composerView ("thread:" ++ String.fromInt threadId) "Reply to thread" model
                ]
        Nothing -> div [ class "empty" ] [ text "Loading thread..." ]

replyView : Reply -> Html Msg
replyView r =
    div [ class "post card" ]
        [ div [ class "post-meta" ]
            [ avatarImg r.avatarUrl r.displayName ""
            , b [] [ text r.displayName ]
            , span [ class "muted" ] [ text (ago r.createdAt ++ " ago") ]
            ]
        , div [ class "msg-body" ] [ text r.body ]
        ]

renderDmsPage : Model -> Html Msg
renderDmsPage model =
    div [ class "dm-inbox" ]
        [ div [ class "section-head" ]
            [ div []
                [ h2 [] [ text "Direct Messages" ]
                , p [ class "muted" ] [ text "Private chats and groups." ]
                ]
            , button [ class "btn", onClick NewDmModal ] [ text "New DM" ]
            ]
        , div [ class "card dm-list-card" ]
            (if List.isEmpty model.convs then
                [ div [ class "empty dm-empty" ]
                    [ h2 [] [ text "No messages yet" ]
                    , p [] [ text "Start a conversation from Friends or New DM." ]
                    ]
                ]
             else
                List.map (\c -> convRow c model) model.convs
            )
        ]

renderFriendsPage : Model -> Html Msg
renderFriendsPage model =
    div []
        [ button [ class "btn", onClick SearchUsersModal ] [ text "Find user" ]
        , div [ class "card" ]
            (if List.isEmpty model.friends then
                [ div [ class "empty" ] [ text "No friends yet." ] ]
             else
                List.map friendRow model.friends
            )
        ]

friendRow : Friend -> Html Msg
friendRow f =
    let statusText = f.status ++ if f.incoming then " · incoming" else ""
    in div [ class "row friend-row" ]
        [ div [ class "clickable-user", onClick (ShowUserPopup f.user.id) ]
            [ avatarImg f.user.avatarUrl f.user.displayName "" ]
        , div [ class "grow clickable-user", onClick (ShowUserPopup f.user.id) ]
            [ b [] [ text f.user.displayName ]
            , small [ class "muted" ] [ text ("@" ++ f.user.username ++ " · " ++ statusText) ]
            ]
        , div [ class "friend-actions" ]
            [ if f.incoming then button [ class "btn", onClick (BridgeEvent "accept_friend" (E.int f.user.id)) ] [ text "Accept" ] else text ""
            , button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int f.user.id)) ] [ text "Call" ]
            , button [ class "btn secondary", onClick (BridgeEvent "dm_user" (E.int f.user.id)) ] [ text "Message" ]
            ]
        ]

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
                        , div [ class "nav-actions" ]
                            [ button [ class "btn", onClick (InviteModal data.server.id) ] [ text "Invite people" ]
                            , button [ class "btn secondary", onClick (ChannelModal data.server.id) ] [ text "Add channel" ]
                            , button [ class "btn secondary", onClick (EditServerModal data.server) ] [ text "Customize" ]
                            ]
                        ]
                    ]
                , h3 [ class "server-section-title" ] [ text "Channels" ]
                , div [ class "card" ] (List.map channelRow data.channels)
                , h3 [ class "server-section-title" ] [ text "Members" ]
                , div [ class "card" ] (List.map memberRow data.members)
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

memberRow : ServerMember -> Html Msg
memberRow m =
    div [ class "row member-row clickable-user", onClick (ShowUserPopup m.user.id) ]
        [ avatarImg m.user.avatarUrl m.user.displayName ""
        , div [ class "grow" ]
            [ b [] [ text m.user.displayName ]
            , small [ class "muted" ] [ text ("@" ++ m.user.username ++ " · " ++ m.role) ]
            ]
        , span [ class ("status-dot " ++ statusToString m.user.status) ] []
        ]

renderVoicePage : Int -> Model -> Html Msg
renderVoicePage channelId model =
    div []
        [ div [ class "card pad" ]
            [ h2 [] [ text "Voice channel" ]
            , p [ class "muted" ] [ text "Join when you want to talk." ]
            , button [ class "btn", onClick (BridgeEvent "join_voice" (E.int channelId)) ] [ text "Join voice" ]
            ]
        ]

renderProfilePage : Model -> Html Msg
renderProfilePage model =
    case model.currentProfile of
        Just u ->
            div [ class "card profile" ]
                [ div [ class "banner", style "background-image" (if String.isEmpty u.bannerUrl then "none" else "url('" ++ u.bannerUrl ++ "')") ] []
                , div [ class "profile-body" ]
                    [ avatarImg u.avatarUrl u.displayName "big"
                    , div []
                        [ h1 [] [ text u.displayName ]
                        , p [ class "muted" ] [ text ("@" ++ u.username ++ " · seen " ++ ago u.lastSeen ++ " ago") ]
                        , p [] [ text (if String.isEmpty u.bio then "No bio set." else u.bio) ]
                        , p [] [ span [ class "pill" ] [ text (statusToString u.status) ] ]
                        , div [ class "nav-actions" ]
                            [ button [ class "btn", onClick (BridgeEvent "friend_user" (E.int u.id)) ] [ text "Friend" ]
                            , button [ class "btn secondary", onClick (BridgeEvent "call_user" (E.int u.id)) ] [ text "Call" ]
                            , button [ class "btn secondary", onClick (BridgeEvent "dm_user" (E.int u.id)) ] [ text "Message" ]
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
                    [ a [ class ("settings-tab" ++ if model.settingsTab == "profile" then " active" else ""), onClick (SetSettingsTab "profile") ] [ text "My Profile" ]
                    , a [ class ("settings-tab" ++ if model.settingsTab == "sound" then " active" else ""), onClick (SetSettingsTab "sound") ] [ text "Notifications" ]
                    , a [ class ("settings-tab" ++ if model.settingsTab == "account" then " active" else ""), onClick (SetSettingsTab "account") ] [ text "Account" ]
                    ]
                , div [ class "settings-content" ]
                    [ case model.settingsTab of
                        "sound" -> div [ class "settings-card" ] [ h2 [] [ text "Notifications" ], button [ class "btn", onClick ToggleSound ] [ text (if model.soundEnabled then "Sound: on" else "Sound: off") ] ]
                        "account" -> div [ class "settings-card" ] [ h2 [] [ text "Account" ], button [ class "btn danger", onClick Logout ] [ text "Logout" ] ]
                        _ -> renderProfileSettings u model
                    ]
                ]
        Nothing -> text ""

renderProfileSettings : User -> Model -> Html Msg
renderProfileSettings u model =
    div [ class "settings-card" ]
        [ div [ class "settings-banner", style "background-image" (if String.isEmpty model.profileBannerUrl then "linear-gradient(135deg, #5865f2, #232946)" else "url('" ++ model.profileBannerUrl ++ "')") ]
            [ div [ class "settings-avatar-wrap" ] [ avatarImg model.profileAvatarUrl model.profileDisplayName "" ]
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
            ]
        , div [ class "field" ]
            [ label [] [ text "Banner URL" ]
            , input [ value model.profileBannerUrl, placeholder "https://...", onInput ProfileBannerUrl ] []
            ]
        , div [ class "field" ]
            [ label [] [ text "Status" ]
            , select [ value model.profileStatus, onInput ProfileStatus ]
                [ option [ value "online" ] [ text "Online" ]
                , option [ value "away" ] [ text "Away" ]
                , option [ value "busy" ] [ text "Busy" ]
                , option [ value "invisible" ] [ text "Invisible" ]
                , option [ value "offline" ] [ text "Offline" ]
                ]
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
            [ button [ class "btn", onClick SaveProfile ] [ text "Save profile" ] ]
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
    div [ class "chat-surface" ]
        [ renderChatHeader model
        , div [ class "messages", id "messages" ]
            (if List.isEmpty model.msg then
                [ div [ class "empty chat-empty" ] [ h2 [] [ text "Start the conversation" ], p [ class "muted" ] [ text "Messages appear here instantly when people post." ] ] ]
             else
                groupedMessageViews model model.msg
            )
        , composerView draftKey placeholderText model
        ]

renderChatHeader : Model -> Html Msg
renderChatHeader model =
    case model.active of
        DmView id ->
            case List.filter (\c -> c.id == id) model.convs of
                c :: _ ->
                    div [ class "chat-header" ]
                        [ convAvatar c
                        , div [ class "grow" ]
                            [ h2 [] [ text (convName c) ]
                            , small [ class "muted" ] [ text (if c.memberCount > 2 then String.fromInt c.memberCount ++ " people" else "Direct message") ]
                            ]
                        , button [ class "btn secondary", onClick (AddPeopleModal c.id) ] [ text "Add" ]
                        ]
                [] -> chatOnlineHeader
        ChannelView _ -> chatOnlineHeader
        _ -> chatOnlineHeader

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
    in div [ class ("msg" ++ (if mine then " mine" else "") ++ (if grouped then " compact" else "") ++ (if m.id < 0 then " pending" else "")), attribute "data-mid" (String.fromInt m.id), onContextMenu (OpenMessageCtx m) ]
        [ if grouped then div [ class "avatar avatar-spacer" ] [] else avatarImg m.avatarUrl m.displayName ""
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
            , div [ class "msg-body" ] [ text m.body ]
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
                    , span [ class "reply-preview-text" ] [ text reply.body ]
                    , button [ class "btn secondary", onClick CancelReply ] [ text "Cancel" ]
                    ]
            Nothing -> text ""
        , textarea [ id "compose", placeholder placeholderText, value model.inputText, onInput InputText, onComposerKeyDown ] []
        , div [ class "composer-footer" ]
            [ small [ class "muted" ] [ text "Write a message." ]
            , button [ class "btn", disabled (String.isEmpty (String.trim model.inputText)), onClick SendMessage ] [ text "Send" ]
            ]
        ]

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
    div []
        [ button [ class "btn secondary", onClick ClearNotifs ] [ text "Mark seen" ]
        , div [ class "card" ]
            (if List.isEmpty model.notifs then
                [ div [ class "empty" ] [ text "No notifications." ] ]
             else
                List.map notificationView model.notifs
            )
        ]

notificationView : Notification -> Html Msg
notificationView n =
    a [ class ("row notif" ++ if n.seen then "" else " unseen"), onClick (Go n.url) ]
        [ div [ class "grow" ]
            [ b [] [ text n.kind ]
            , small [] [ text n.body ]
            ]
        , span [ class "muted" ] [ text (ago n.createdAt ++ " ago") ]
        ]

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
        , button [ class "btn secondary", onClick (BridgeEvent "friend_user" (E.int u.id)) ] [ text "Add" ]
        , button [ class "btn", onClick (BridgeEvent "dm_user" (E.int u.id)) ] [ text "Message" ]
        ]

searchThreadView : ForumThread -> Html Msg
searchThreadView t =
    div [ class "row", onClick (Go ("#thread/" ++ String.fromInt t.id)) ]
        [ div [] [ b [] [ text t.title ], small [ class "muted" ] [ text t.forumName ] ] ]


-- HELPERS

parseRoute : String -> ActiveRoute
parseRoute s =
    if s == "" || s == "home" then Home
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
        "bad_login" -> "Username or password is incorrect."
        "invalid_json" -> "Could not send the form. Please try again."
        "database_unavailable" -> "The server database is temporarily unavailable."
        "database_timeout" -> "The server database timed out. Please try again."
        "rate_limited" -> "Too many attempts. Wait a moment and try again."
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
        Err _ -> ApiError "" "request_failed"

apiDecoder : Decoder Msg
apiDecoder =
    D.map4 apiMsg
        (D.field "path" D.string)
        (D.field "ok" D.bool)
        (D.oneOf [ D.field "data" D.value, D.succeed E.null ])
        (D.oneOf [ D.field "error" D.string, D.succeed "request_failed" ])

apiMsg : String -> Bool -> E.Value -> String -> Msg
apiMsg path ok data err =
    if ok then ApiSuccess path data else ApiError path err

ago : Int -> String
ago t =
    agoAt 0 t

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
        , Browser.Events.onVisibilityChange (\_ -> NoOp)
        , Time.every 3000 Tick
        ]
