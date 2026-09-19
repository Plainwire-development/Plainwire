module Types exposing
    ( ActiveCall
    , ActiveRoute(..)
    , AudioDevice
    , CallMode(..)
    , CallPopup
    , CallUI
    , CallUser
    , BotCommand
    , Category
    , Channel
    , ContextMenu
    , Conversation
    , CtxItem
    , Forum
    , ForumThread
    , Friend
    , InvitePreview
    , MemberUser
    , Message
    , Reaction
    , Model
    , Msg(..)
    , Notification
    , PageState
    , Relationship(..)
    , Reply
    , Route(..)
    , Server
    , ServerData
    , ServerMember
    , ServerProfile
    , ServerProfileRole
    , Status(..)
    , User
    , VoiceState
    , VoiceUser
    , decodeBotCommand
    , decodeCallUser
    , decodeCategory
    , decodeChannel
    , decodeConversation
    , decodeForum
    , decodeFriend
    , decodeMemberUser
    , decodeMessage
    , decodeReaction
    , decodeNotification
    , decodeReply
    , decodeServer
    , decodeServerMember
    , decodeSyncData
    , decodeThread
    , decodeUser
    , defaultMsg
    , defaultValue
    , encodeMessage
    , statusToString
    )

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode as E
import Set exposing (Set)
import Time


defaultValue : a -> D.Decoder a -> D.Decoder a
defaultValue fallback decoder =
    D.oneOf [ decoder, D.succeed fallback ]


resilientList : D.Decoder a -> D.Decoder (List a)
resilientList decoder =
    -- one weird old row should not eat the whole nav list.
    D.list (D.maybe decoder)
        |> D.map (List.filterMap identity)


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap valueDecoder functionDecoder =
    D.map2 (\f value -> f value) functionDecoder valueDecoder



-- BASIC TYPES


type Status
    = Online
    | Away
    | Busy
    | Invisible
    | Offline


type Relationship
    = None
    | Pending
    | Accepted
    | Blocked
    | Self



-- DATA TYPES


type alias User =
    { id : Int
    , username : String
    , displayName : String
    , avatarUrl : String
    , bannerUrl : String
    , bio : String
    , status : Status
    , theme : String
    , lastSeen : Int
    , createdAt : Int
    , isBot : Bool
    }


type alias Conversation =
    { id : Int
    , name : String
    , avatarUrl : String
    , ownerId : Int
    , createdAt : Int
    , updatedAt : Int
    , lastReadMessageId : Int
    , muted : Bool
    , requestState : String
    , groupRole : String
    , memberCount : Int
    , lastBody : Maybe String
    , lastMessageId : Maybe Int
    , lastSenderId : Int
    , lastSenderName : String
    , lastSenderUsername : String
    , unread : Int
    , members : List MemberUser
    , peerId : Int
    , peerName : String
    , peerAvatarUrl : String
    , peerUsername : String
    }


type alias MemberUser =
    { user : User, role : String, muted : Bool, joinedAt : Int }


type alias Message =
    { id : Int
    , scope : String
    , scopeId : Int
    , userId : Int
    , username : String
    , displayName : String
    , avatarUrl : String
    , body : String
    , kind : String
    , replyToId : Maybe Int
    , replyTo : Maybe ReplyPreview
    , createdAt : Int
    , editedAt : Maybe Int
    , deletedAt : Maybe Int
    , forwardedFrom : Maybe ForwardPreview
    , roleColor : String
    , isBot : Bool
    , pinned : Bool
    , reactions : List Reaction
    }


type alias Reaction =
    { emoji : String
    , count : Int
    , me : Bool
    }


type alias ReplyPreview =
    { id : Int, userId : Int, displayName : String, body : String }


type alias ForwardPreview =
    { id : Int, userId : Int, displayName : String, body : String }


type alias Forum =
    { id : Int
    , slug : String
    , name : String
    , description : String
    , position : Int
    , threadCount : Int
    , replyCount : Int
    , lastAt : Maybe Int
    , memberCount : Int
    , joined : Bool
    , ownerId : Maybe Int
    }


type alias ForumThread =
    { id : Int
    , forumId : Int
    , forumName : String
    , userId : Int
    , username : String
    , displayName : String
    , avatarUrl : String
    , title : String
    , body : String
    , rawBody : String
    , createdAt : Int
    , updatedAt : Int
    , replyCount : Int
    , views : Int
    , locked : Bool
    , pinned : Bool
    , score : Int
    , userVote : Int
    , canEdit : Bool
    , canDelete : Bool
    , canModerate : Bool
    , viewerJoined : Bool
    }


type alias Reply =
    { id : Int
    , threadId : Int
    , userId : Int
    , username : String
    , displayName : String
    , avatarUrl : String
    , body : String
    , rawBody : String
    , createdAt : Int
    , updatedAt : Int
    , canEdit : Bool
    , canDelete : Bool
    }


type alias Server =
    { id : Int
    , name : String
    , description : String
    , iconUrl : String
    , bannerUrl : String
    , accentColor : String
    , welcomeMessage : String
    , ownerId : Int
    , role : String
    , memberCount : Int
    , createdAt : Int
    , permissions : Int
    }


type alias Channel =
    { id : Int
    , serverId : Int
    , name : String
    , kind : String
    , position : Int
    , topic : String
    , createdAt : Int
    , categoryId : Maybe Int
    , slowmodeSeconds : Int
    }


type alias BotCommand =
    { id : Int
    , name : String
    , description : String
    , botId : Int
    , botUserId : Int
    , botName : String
    , botDisplayName : String
    , botAvatarUrl : String
    }


type alias Category =
    { id : Int
    , serverId : Int
    , name : String
    , position : Int
    , createdAt : Int
    }


type alias ServerMember =
    { user : User
    , role : String
    , muted : Bool
    , joinedAt : Int
    , nickname : String
    , serverAvatarUrl : String
    , serverBio : String
    , roleColor : String
    , roleNames : String
    }


type alias ServerProfileRole =
    { id : Int
    , name : String
    , color : String
    , permissions : Int
    , position : Int
    }


type alias ServerProfile =
    { serverId : Int
    , serverName : String
    , member : ServerMember
    , roles : List ServerProfileRole
    , canManageRoles : Bool
    , canBanMembers : Bool
    }


type alias Friend =
    { user : User, status : String, incoming : Bool, outgoing : Bool, blockedByMe : Bool }


type alias Notification =
    { id : Int
    , kind : String
    , body : String
    , url : String
    , seen : Bool
    , createdAt : Int
    }



-- VOICE / CALL STATE


type alias VoiceState =
    { mode : Maybe String
    , id : Maybe Int
    , stream : Maybe String
    , peers : Dict Int Bool
    , failedPeers : Dict Int Bool
    , users : Dict Int VoiceUser
    , muted : Bool
    , deafened : Bool
    , mutedBeforeDeafen : Bool
    , screenShare : Bool
    }


type alias VoiceUser =
    { userId : Int
    , displayName : String
    , avatarUrl : String
    , muted : Bool
    , deafened : Bool
    , screen : Bool
    , screenAudio : Bool
    , reconnecting : Bool
    }


type alias CallUser =
    { userId : Int
    , displayName : String
    , avatarUrl : String
    , muted : Bool
    , deafened : Bool
    , connected : Bool
    , connectionFailed : Bool
    , reconnecting : Bool
    , screen : Bool
    , screenAudio : Bool
    }


type alias ActiveCall =
    { conversationId : Int
    , users : List CallUser
    , startTime : Int
    , expanded : Bool
    }


type alias CallUI =
    { incoming : Maybe CallPopup
    , outgoing : Maybe CallPopup
    , active : Maybe ActiveCall
    }


type alias CallPopup =
    { conversationId : Int
    , userId : Int
    , displayName : String
    , avatarUrl : String
    }


type CallMode
    = Idle
    | Ringing
    | Calling
    | Connected
    | InCall


type alias AudioDevice =
    { id : String, label : String }



-- ROUTING


type ActiveRoute
    = Home
    | Forums
    | ForumView Int
    | ThreadView Int
    | Dms
    | DmView Int
    | Friends
    | ProfileView Int
    | Settings
    | NewServer
    | ServerView Int
    | ChannelView Int
    | VoiceChannelView Int
    | InviteView String
    | Notifications
    | SearchView String
    | SourceHub


type Route
    = HomeRoute
    | HashRoute String



-- MAIN MODEL


type alias PageState =
    { route : ActiveRoute, serverCache : Dict Int ServerData }


type alias ServerData =
    { server : Server
    , channels : List Channel
    , members : List ServerMember
    , categories : List Category
    }


type alias Drafts =
    Dict String String


type alias Model =
    { appName : String
    , registrationEnabled : Bool
    , instanceDescription : String
    , clientVersion : String
    , me : Maybe User
    , csrf : String
    , serverTime : Int
    , timeZone : Time.Zone
    , absoluteTimestamps : Bool
    , forums : List Forum
    , threads : List ForumThread
    , currentThread : Maybe ForumThread
    , replies : List Reply
    , servers : List Server
    , convs : List Conversation
    , conversationMembers : Dict Int (List MemberUser)
    , friends : List Friend
    , notifs : List Notification
    , searchUsers : List User
    , searchThreads : List ForumThread
    , searchMessages : List Message
    , availableCommands : List BotCommand
    , currentServer : Maybe ServerData
    , currentProfile : Maybe User
    , currentServerProfile : Maybe ServerProfile
    , invitePreview : Maybe InvitePreview
    , msg : List Message
    , pinnedMessages : List Message
    , messageContextMode : Bool
    , nextBefore : Maybe Int
    , loadingOlderMessages : Bool
    , hasOlderMessages : Bool
    , active : ActiveRoute
    , serverCache : Dict Int ServerData
    , drafts : Drafts
    , wsConnected : Bool
    , pageVisible : Bool
    , isLeader : Bool
    , tabId : String
    , subs : Set String
    , mentionHints : Set String
    , voice : VoiceState
    , callUI : CallUI
    , activeCalls : Dict Int ActiveCall
    , callMode : CallMode
    , soundEnabled : Bool
    , chatEnterSends : Bool
    , linkPreviewsEnabled : Bool
    , animatedMediaEnabled : Bool
    , compactMessages : Bool
    , mediaPreloadEnabled : Bool
    , uiDensity : String
    , uiFontScale : String
    , uiAccent : String
    , uiCornerStyle : String
    , reduceMotion : Bool
    , replyTo : Maybe ReplyPreview
    , toast : Maybe String
    , modal : Maybe String
    , settingsSearch : String
    , settingsTab : String
    , inputText : String
    , editingMessageId : Maybe Int
    , editingMessageText : String
    , sidebarOpen : Bool
    , serversSheetOpen : Bool
    , ctxMenu : Maybe ContextMenu
    , threadReply : String
    , searchQuery : String
    , authMode : String
    , authUsername : String
    , authBusy : Bool
    , authDisplayName : String
    , authPassword : String
    , authPasswordConfirm : String
    , authPasswordVisible : Bool
    , profileDisplayName : String
    , profileBio : String
    , profileAvatarUrl : String
    , profileBannerUrl : String
    , profileAvatarPreviewUrl : String
    , profileBannerPreviewUrl : String
    , profileAvatarUploading : Bool
    , profileBannerUploading : Bool
    , profileStatus : String
    , profileTheme : String
    , serverName : String
    , serverDescription : String
    , modalTitle : String
    , modalBody : String
    , modalPeopleQuery : String
    , modalUserIds : String
    , modalBannerUrl : String
    , modalWelcome : String
    , modalAccentColor : String
    , friendsTab : String
    , friendQuery : String
    , friendSearchAttempted : Bool
    , booting : Bool
    , userStatuses : Dict String String
    , failedMsgIds : Set Int
    , currentProfileRelationship : String
    , currentProfileBlockedByMe : Bool
    , pendingMessages : Dict Int String
    , outbox : Dict Int Message
    , nextMessageId : Int
    , pendingConversationId : Maybe Int
    , collapsedCategories : Set Int
    , audioInputs : List AudioDevice
    , audioOutputs : List AudioDevice
    , selectedAudioInput : String
    , selectedAudioOutput : String
    , outputSelectionSupported : Bool
    , voiceProcessingMode : String
    , krispAvailable : Bool
    , micTesting : Bool
    , micTestLevel : Int
    , micMonitoring : Bool
    }


type alias InvitePreview =
    { code : String
    , serverId : Int
    , channelId : Maybe Int
    , valid : Bool
    , serverName : String
    , serverDescription : String
    , serverIconUrl : String
    , memberCount : Int
    }


type alias ContextMenu =
    { items : List CtxItem, x : Int, y : Int }


type alias CtxItem =
    { label : String
    , icon : Maybe String
    , danger : Bool
    , sep : Bool
    , msg : Msg
    }



-- MSG


type Msg
    = NoOp
    | SetRoute String
    | AuthMode String
    | AuthUsername String
    | AuthDisplayName String
    | AuthPassword String
    | AuthPasswordConfirm String
    | ToggleAuthPasswordVisibility
    | DoAuth
    | ApiSuccess String String (Maybe Int) E.Value
    | ApiError String String (Maybe Int) String
    | WsEvent E.Value
    | BridgeEvent String E.Value
    | Go String
    | ToggleSidebar
    | CloseSidebar
    | ToggleServersSheet
    | CloseServersSheet
    | ShowUserPopup Int
    | ShowServerProfile Int Int
    | CloseModal
    | Toast String
    | DismissToast
    | GotTimeZone Time.Zone
    | ToggleTimestampMode
    | SetReplyTo Message
    | JumpToMessage Int
    | OpenPinnedMessages Int
    | SetMessagePinned Message Bool
    | ReturnToLatestMessages
    | CancelReply
    | ClearDrafts
    | AttachmentReady String String
    | ToggleLastAttachmentSpoiler
    | InputText String
    | SendMessage
    | StartEditMessage Message
    | EditMessageText String
    | CancelEditMessage
    | SaveEditMessage Int
    | InsertComposerText String
    | OpenForwardModal Message
    | ForwardMessage Int String Int
    | DeleteMessage Int
    | ToggleReaction Int String
    | OpenReactionPicker Int
    | LeaveConversation Int
    | CloseConversation Int
    | RetryMessage Int
    | DismissFailedMessage Int
    | MarkConvRead Int
    | OpenMessageCtx Message Int Int
    | OpenConvCtx Conversation Int Int
    | OpenUserCtx User Int Int
    | OpenServerCtx Server Int Int
    | OpenServerMemberCtx Int ServerMember Int Int
    | OpenChannelCtx Channel Int Int
    | CopyText String
    | JoinInvite
    | NewDmModal
    | SearchUsersModal
    | InviteModal Int
    | ChannelModal Int
    | ChannelModalInCategory Int Int
    | EditServerModal Server
    | OpenDeleteServer Server
    | ConfirmDeleteServer Int
    | EditCategoryModal Int Category
    | EditConversationModal Conversation
    | NewThreadModal (Maybe Int)
    | NewForumModal
    | ModalTitle String
    | ModalBody String
    | ModalUserIds String
    | ModalBannerUrl String
    | ModalAccentColor String
    | SetModalChoice String String
    | SubmitModal
    | JoinForum Int
    | LeaveForum Int
    | VoteThread Int Int
    | CreateServer String String
    | ProfileDisplayName String
    | ProfileBio String
    | ProfileAvatarUrl String
    | ProfileBannerUrl String
    | ProfileStatus String
    | ProfileTheme String
    | SaveProfile
    | ServerName String
    | ServerDescription String
    | ToggleSound
    | SetSoundPreference Bool
    | SetChatEnterSends Bool
    | SetLinkPreviewsEnabled Bool
    | SetAnimatedMediaEnabled Bool
    | SetCompactMessages Bool
    | SetMediaPreloadEnabled Bool
    | UiPreferences E.Value
    | Logout
    | CloseCtx
    | CtxAction Int
    | LoadMoreMessages
    | SilentSync Bool
    | Tick Time.Posix
    | WsStatus Bool
    | PageVisibility Bool
    | RtcResuming String Int Bool Bool Bool
    | FileUpload String (Maybe String)
    | ReadFile String
    | SettingsSearch String
    | SetSettingsTab String
    | SetFriendsTab String
    | FriendQuery String
    | FindFriends
    | ClearNotifs
    | SearchQuery String
    | DoSearch
    | AddPeopleModal Int
    | JoinCall Int
    | StartCall Int
    | AcceptCall Int
    | DeclineCall Int
    | EndCall
    | CallSignal Int String
    | ToggleCallOverlay
    | SetCallPeerConnected String Int Int Bool
    | SetCallPeerFailed String Int Int Bool
    | RtcAudioState Bool Bool
    | RetryCallPeer Int
    | PresenceState E.Value
    | PresenceOnline Int String
    | PresenceOffline Int
    | PresenceStatus Int String
    | SetMyStatus String
    | StartScreenShare
    | StopScreenShare
    | CreateCategoryModal Int
    | DeleteCategory Int Int
    | ToggleCategory Int
    | MoveChannelToCategory Int (Maybe Int)
    | RtcJoinFailed String
    | AudioDevices E.Value
    | SelectAudioInput String
    | SelectAudioOutput String
    | SelectVoiceProcessing String
    | ToggleMicTest
    | ToggleMicMonitor
    | MicTestLevel Int
    | MicTestFailed String
    | ShortcutAction String



-- DECODERS


decodeUser : D.Decoder User
decodeUser =
    D.succeed User
        |> andMap (D.field "id" D.int)
        |> andMap (D.field "username" D.string)
        |> andMap (D.field "display_name" D.string)
        |> andMap (D.field "avatar_url" D.string)
        |> andMap (D.field "banner_url" D.string |> defaultValue "")
        |> andMap (D.field "bio" D.string)
        |> andMap (D.field "status" statusDecoder)
        |> andMap (D.field "theme" D.string |> defaultValue "system")
        |> andMap (D.field "last_seen" D.int)
        |> andMap (D.field "created_at" D.int)
        |> andMap (D.field "is_bot" D.bool |> defaultValue False)


decodeConversation : D.Decoder Conversation
decodeConversation =
    D.succeed Conversation
        |> andMap (D.field "id" D.int)
        |> andMap (D.field "name" D.string |> defaultValue "")
        |> andMap (D.field "avatar_url" D.string |> defaultValue "")
        |> andMap (D.field "owner_id" D.int)
        |> andMap (D.field "created_at" D.int)
        |> andMap (D.field "updated_at" D.int)
        |> andMap (D.field "last_read_message_id" D.int |> defaultValue 0)
        |> andMap (D.field "muted" D.bool |> defaultValue False)
        |> andMap (D.field "request_state" D.string |> defaultValue "accepted")
        |> andMap (D.field "group_role" D.string |> defaultValue "member")
        |> andMap (D.field "member_count" D.int |> defaultValue 1)
        |> andMap (D.field "last_body" (D.nullable D.string))
        |> andMap (D.field "last_message_id" (D.nullable D.int))
        |> andMap (D.field "last_sender_id" D.int |> defaultValue 0)
        |> andMap (D.field "last_sender_name" D.string |> defaultValue "")
        |> andMap (D.field "last_sender_username" D.string |> defaultValue "")
        |> andMap (D.field "unread" D.int |> defaultValue 0)
        |> andMap (D.field "members" (D.list decodeMemberUser) |> defaultValue [])
        |> andMap (D.field "peer_id" D.int |> defaultValue 0)
        |> andMap (D.field "peer_name" D.string |> defaultValue "")
        |> andMap (D.field "peer_avatar_url" D.string |> defaultValue "")
        |> andMap (D.field "peer_username" D.string |> defaultValue "")


decodeMemberUser : D.Decoder MemberUser
decodeMemberUser =
    D.map4 MemberUser
        (D.field "user" decodeUser)
        (D.field "role" D.string |> defaultValue "member")
        (D.field "muted" D.bool |> defaultValue False)
        (D.field "joined_at" D.int |> defaultValue 0)


decodeMessage : D.Decoder Message
decodeMessage =
    D.succeed Message
        |> andMap (D.field "id" D.int)
        |> andMap (D.field "scope" D.string)
        |> andMap (D.field "scope_id" D.int)
        |> andMap (D.field "user_id" D.int)
        |> andMap (D.field "username" D.string)
        |> andMap (D.field "display_name" D.string)
        |> andMap (D.field "avatar_url" D.string |> defaultValue "")
        |> andMap (D.field "body" D.string)
        |> andMap (D.field "kind" D.string |> defaultValue "text")
        |> andMap (D.field "reply_to_id" (D.nullable D.int))
        |> andMap (D.field "reply_to" (D.nullable decodeReplyPreview) |> defaultValue Nothing)
        |> andMap (D.field "created_at" D.int)
        |> andMap (D.field "edited_at" (D.nullable D.int))
        |> andMap (D.field "deleted_at" (D.nullable D.int))
        |> andMap (D.field "forwarded_from" (D.nullable decodeForwardPreview) |> defaultValue Nothing)
        |> andMap (D.field "role_color" D.string |> defaultValue "")
        |> andMap (D.field "is_bot" D.bool |> defaultValue False)
        |> andMap (D.field "pinned" D.bool |> defaultValue False)
        |> andMap (D.field "reactions" (D.list decodeReaction) |> defaultValue [])


decodeReaction : D.Decoder Reaction
decodeReaction =
    D.map3 Reaction
        (D.field "emoji" D.string)
        (D.field "count" D.int)
        (D.field "me" D.bool |> defaultValue False)


decodeForwardPreview : D.Decoder ForwardPreview
decodeForwardPreview =
    D.map4 ForwardPreview
        (D.field "id" D.int)
        (D.field "user_id" D.int)
        (D.field "display_name" D.string)
        (D.field "body" D.string)


decodeReplyPreview : D.Decoder ReplyPreview
decodeReplyPreview =
    D.map4 ReplyPreview
        (D.field "id" D.int)
        (D.field "user_id" D.int)
        (D.field "display_name" D.string)
        (D.field "body" D.string)


decodeForum : D.Decoder Forum
decodeForum =
    D.map8
        (\id slug name description position threadCount replyCount lastAt ->
            \memberCount joined ownerId -> Forum id slug name description position threadCount replyCount lastAt memberCount joined ownerId
        )
        (D.field "id" D.int)
        (D.field "slug" D.string)
        (D.field "name" D.string)
        (D.field "description" D.string)
        (D.field "position" D.int)
        (D.field "thread_count" D.int |> defaultValue 0)
        (D.field "reply_count" D.int |> defaultValue 0)
        (D.field "last_at" (D.nullable D.int))
        |> andMap (D.field "member_count" D.int |> defaultValue 0)
        |> andMap (D.field "joined" D.bool |> defaultValue False)
        |> andMap (D.field "owner_id" (D.nullable D.int) |> defaultValue Nothing)


decodeThread : D.Decoder ForumThread
decodeThread =
    D.succeed ForumThread
        |> andMap (D.field "id" D.int)
        |> andMap (D.field "forum_id" D.int)
        |> andMap (D.field "forum_name" D.string |> defaultValue "")
        |> andMap (D.field "user_id" D.int)
        |> andMap (D.field "username" D.string)
        |> andMap (D.field "display_name" D.string)
        |> andMap (D.field "avatar_url" D.string |> defaultValue "")
        |> andMap (D.field "title" D.string)
        |> andMap (D.field "body" D.string |> defaultValue "")
        |> andMap (D.field "raw_body" D.string |> defaultValue "")
        |> andMap (D.field "created_at" D.int)
        |> andMap (D.field "updated_at" D.int)
        |> andMap (D.field "reply_count" D.int |> defaultValue 0)
        |> andMap (D.field "views" D.int |> defaultValue 0)
        |> andMap (D.field "locked" D.bool |> defaultValue False)
        |> andMap (D.field "pinned" D.bool |> defaultValue False)
        |> andMap (D.field "score" D.int |> defaultValue 0)
        |> andMap (D.field "user_vote" D.int |> defaultValue 0)
        |> andMap (D.field "can_edit" D.bool |> defaultValue False)
        |> andMap (D.field "can_delete" D.bool |> defaultValue False)
        |> andMap (D.field "can_moderate" D.bool |> defaultValue False)
        |> andMap (D.field "viewer_joined" D.bool |> defaultValue False)


decodeReply : D.Decoder Reply
decodeReply =
    D.succeed Reply
        |> andMap (D.field "id" D.int)
        |> andMap (D.field "thread_id" D.int)
        |> andMap (D.field "user_id" D.int)
        |> andMap (D.field "username" D.string)
        |> andMap (D.field "display_name" D.string)
        |> andMap (D.field "avatar_url" D.string |> defaultValue "")
        |> andMap (D.field "body" D.string)
        |> andMap (D.field "raw_body" D.string |> defaultValue "")
        |> andMap (D.field "created_at" D.int)
        |> andMap (D.field "updated_at" D.int)
        |> andMap (D.field "can_edit" D.bool |> defaultValue False)
        |> andMap (D.field "can_delete" D.bool |> defaultValue False)


decodeServer : D.Decoder Server
decodeServer =
    D.succeed Server
        |> andMap (D.field "id" D.int)
        |> andMap (D.field "name" D.string)
        |> andMap (D.field "description" D.string |> defaultValue "")
        |> andMap (D.field "icon_url" D.string |> defaultValue "")
        |> andMap (D.field "banner_url" D.string |> defaultValue "")
        |> andMap (D.field "accent_color" D.string |> defaultValue "#5865f2")
        |> andMap (D.field "welcome_message" D.string |> defaultValue "")
        |> andMap (D.field "owner_id" D.int)
        |> andMap (D.field "role" D.string |> defaultValue "member")
        |> andMap (D.field "member_count" D.int |> defaultValue 1)
        |> andMap (D.field "created_at" D.int)
        |> andMap (D.field "permissions" D.int |> defaultValue 0)


decodeBotCommand : D.Decoder BotCommand
decodeBotCommand =
    D.map8 BotCommand
        (D.field "id" D.int)
        (D.field "name" D.string)
        (D.field "description" D.string |> defaultValue "")
        (D.at [ "bot", "id" ] D.int)
        (D.at [ "bot", "user_id" ] D.int)
        (D.at [ "bot", "name" ] D.string |> defaultValue "")
        (D.at [ "bot", "display_name" ] D.string |> defaultValue "")
        (D.at [ "bot", "avatar_url" ] D.string |> defaultValue "")


decodeChannel : D.Decoder Channel
decodeChannel =
    D.map2 (\partial slowmode -> partial slowmode)
        (D.map8 Channel
            (D.field "id" D.int)
            (D.field "server_id" D.int)
            (D.field "name" D.string)
            (D.field "kind" D.string)
            (D.field "position" D.int)
            (D.field "topic" D.string |> defaultValue "")
            (D.field "created_at" D.int)
            (D.field "category_id" (D.nullable D.int) |> defaultValue Nothing)
        )
        (D.field "slowmode_seconds" D.int |> defaultValue 0)


decodeCategory : D.Decoder Category
decodeCategory =
    D.map5 Category
        (D.field "id" D.int)
        (D.field "server_id" D.int)
        (D.field "name" D.string)
        (D.field "position" D.int)
        (D.field "created_at" D.int)


decodeServerMember : D.Decoder ServerMember
decodeServerMember =
    D.succeed ServerMember
        |> andMap (D.field "user" decodeUser)
        |> andMap (D.field "role" D.string |> defaultValue "member")
        |> andMap (D.field "muted" D.bool |> defaultValue False)
        |> andMap (D.field "joined_at" D.int |> defaultValue 0)
        |> andMap (D.field "nickname" D.string |> defaultValue "")
        |> andMap (D.field "server_avatar_url" D.string |> defaultValue "")
        |> andMap (D.field "server_bio" D.string |> defaultValue "")
        |> andMap (D.field "role_color" D.string |> defaultValue "")
        |> andMap (D.field "role_names" D.string |> defaultValue "")


decodeFriend : D.Decoder Friend
decodeFriend =
    D.map5 Friend
        (D.field "user" decodeUser)
        (D.field "status" D.string |> defaultValue "accepted")
        (D.field "incoming" D.bool |> defaultValue False)
        (D.field "outgoing" D.bool |> defaultValue False)
        (D.field "blocked_by_me" D.bool |> defaultValue False)


decodeNotification : D.Decoder Notification
decodeNotification =
    D.map6 Notification
        (D.field "id" D.int)
        (D.field "kind" D.string)
        (D.field "body" D.string)
        (D.field "url" D.string |> defaultValue "#")
        (D.field "seen" D.bool)
        (D.field "created_at" D.int)


decodeSyncData : D.Decoder { notifications : List Notification, conversations : List Conversation, servers : List Server, friends : List Friend, now : Int, syncWarnings : List String }
decodeSyncData =
    D.map2
        (\core syncWarnings -> { notifications = core.notifications, conversations = core.conversations, servers = core.servers, friends = core.friends, now = core.now, syncWarnings = syncWarnings })
        (D.map5
            (\notifications conversations servers friends now ->
                { notifications = notifications, conversations = conversations, servers = servers, friends = friends, now = now }
            )
            (D.field "notifications" (resilientList decodeNotification) |> defaultValue [])
            (D.field "conversations" (resilientList decodeConversation) |> defaultValue [])
            (D.field "servers" (resilientList decodeServer) |> defaultValue [])
            (D.field "friends" (resilientList decodeFriend) |> defaultValue [])
            (D.field "now" D.int)
        )
        (D.field "sync_warnings" (D.list D.string) |> defaultValue [])


type alias SyncData r =
    { r | notifications : List Notification, conversations : List Conversation, servers : List Server, friends : List Friend, now : Int, syncWarnings : List String }


defaultMsg : Message
defaultMsg =
    Message 0 "" 0 0 "" "" "" "" "text" Nothing Nothing 0 Nothing Nothing Nothing "" False False []



-- HELPERS


decodeCallUser : D.Decoder CallUser
decodeCallUser =
    D.succeed CallUser
        |> andMap (D.field "user_id" D.int)
        |> andMap (D.oneOf [ D.at [ "profile", "display_name" ] D.string, D.succeed "Unknown" ])
        |> andMap (D.oneOf [ D.at [ "profile", "avatar_url" ] D.string, D.succeed "" ])
        |> andMap (D.field "muted" D.bool |> defaultValue False)
        |> andMap (D.field "deafened" D.bool |> defaultValue False)
        |> andMap (D.field "connected" D.bool |> defaultValue False)
        |> andMap (D.succeed False)
        |> andMap (D.field "reconnecting" D.bool |> defaultValue False)
        |> andMap (D.field "screen" D.bool |> defaultValue False)
        |> andMap (D.field "screen_audio" D.bool |> defaultValue False)


encodeMessage : { body : String, replyToId : Maybe Int } -> E.Value
encodeMessage m =
    E.object
        (List.filterMap identity
            [ Just ( "body", E.string m.body )
            , Maybe.map (\rid -> ( "reply_to_id", E.int rid )) m.replyToId
            ]
        )


statusDecoder : D.Decoder Status
statusDecoder =
    D.string
        |> D.andThen
            (\s ->
                case s of
                    "online" ->
                        D.succeed Online

                    "away" ->
                        D.succeed Away

                    "busy" ->
                        D.succeed Busy

                    "invisible" ->
                        D.succeed Invisible

                    _ ->
                        D.succeed Offline
            )


encodeStatus : Status -> String
encodeStatus s =
    case s of
        Online ->
            "online"

        Away ->
            "away"

        Busy ->
            "busy"

        Invisible ->
            "invisible"

        Offline ->
            ""


statusToString : Status -> String
statusToString s =
    case s of
        Online ->
            "online"

        Away ->
            "away"

        Busy ->
            "busy"

        Invisible ->
            "invisible"

        Offline ->
            "offline"
