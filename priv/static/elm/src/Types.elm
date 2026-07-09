module Types exposing
    ( User, Conversation, Message, Forum, ForumThread, Reply
    , Server, Channel, ServerMember, ServerData, InvitePreview, Friend, Notification
    , VoiceState, CallUI, CallPopup, CallMode(..)
    , ActiveRoute(..), Route(..), Model, PageState
    , Status(..), Relationship(..), Msg(..)
    , decodeUser, decodeConversation, decodeMessage, decodeForum
    , decodeThread, decodeReply, decodeServer, decodeChannel
    , decodeServerMember, decodeFriend, decodeNotification
    , decodeSyncData, encodeMessage, defaultMsg, statusToString
    )

import Json.Decode as D
import Json.Encode as E
import Dict exposing (Dict)
import Set exposing (Set)


defaultValue : a -> D.Decoder a -> D.Decoder a
defaultValue fallback decoder =
    D.oneOf [ decoder, D.succeed fallback ]


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap valueDecoder functionDecoder =
    D.map2 (\f value -> f value) functionDecoder valueDecoder


-- BASIC TYPES

type Status = Online | Away | Busy | Invisible | Offline

type Relationship = None | Pending | Accepted | Blocked | Self


-- DATA TYPES

type alias User =
    { id : Int, username : String, displayName : String
    , avatarUrl : String, bannerUrl : String, bio : String
    , status : Status, theme : String, lastSeen : Int, createdAt : Int
    }

type alias Conversation =
    { id : Int, name : String, avatarUrl : String, ownerId : Int
    , createdAt : Int, updatedAt : Int, lastReadMessageId : Int
    , muted : Bool, memberCount : Int, lastBody : Maybe String
    , lastMessageId : Maybe Int, unread : Int, members : List MemberUser
    }

type alias MemberUser =
    { user : User, role : String, muted : Bool, joinedAt : Int }

type alias Message =
    { id : Int, scope : String, scopeId : Int, userId : Int
    , username : String, displayName : String, avatarUrl : String
    , body : String, replyToId : Maybe Int, replyTo : Maybe ReplyPreview
    , createdAt : Int, editedAt : Maybe Int, deletedAt : Maybe Int
    }

type alias ReplyPreview =
    { id : Int, userId : Int, displayName : String, body : String }

type alias Forum =
    { id : Int, slug : String, name : String, description : String
    , position : Int, threadCount : Int, replyCount : Int, lastAt : Maybe Int
    }

type alias ForumThread =
    { id : Int, forumId : Int, forumName : String, userId : Int
    , username : String, displayName : String, title : String, body : String
    , createdAt : Int, updatedAt : Int, replyCount : Int, views : Int
    , locked : Bool, pinned : Bool
    }

type alias Reply =
    { id : Int, threadId : Int, userId : Int, username : String
    , displayName : String, avatarUrl : String, body : String
    , createdAt : Int, updatedAt : Int
    }

type alias Server =
    { id : Int, name : String, description : String
    , iconUrl : String, ownerId : Int, role : String
    , memberCount : Int, createdAt : Int
    }

type alias Channel =
    { id : Int, serverId : Int, name : String
    , kind : String, position : Int, topic : String, createdAt : Int
    }

type alias ServerMember =
    { user : User, role : String, muted : Bool, joinedAt : Int }

type alias Friend =
    { user : User, status : String, incoming : Bool, outgoing : Bool }

type alias Notification =
    { id : Int, kind : String, body : String, url : String
    , seen : Bool, createdAt : Int
    }


-- VOICE / CALL STATE

type alias VoiceState =
    { mode : Maybe String, id : Maybe Int
    , stream : Maybe String, peers : Dict Int Bool
    , users : Dict Int VoiceUser, muted : Bool, deafened : Bool
    }

type alias VoiceUser = { userId : Int, muted : Bool, deafened : Bool }

type alias CallUI =
    { incoming : Maybe CallPopup, outgoing : Maybe CallPopup }

type alias CallPopup =
    { conversationId : Int, userId : Int, displayName : String
    , avatarUrl : String
    }

type CallMode = Idle | Ringing | Calling | Connected | InCall


-- ROUTING

type ActiveRoute
    = Home | Forums | ForumView Int | ThreadView Int
    | Dms | DmView Int | Friends | ProfileView Int | Settings
    | NewServer | ServerView Int | ChannelView Int | VoiceChannelView Int
    | InviteView String | Notifications | SearchView String

type Route
    = HomeRoute | HashRoute String


-- MAIN MODEL

type alias PageState =
    { route : ActiveRoute, serverCache : Dict Int ServerData }

type alias ServerData =
    { server : Server, channels : List Channel, members : List ServerMember }

type alias Drafts = Dict String String

type alias Model =
    { me : Maybe User, csrf : String, serverTime : Int
    , forums : List Forum, threads : List ForumThread
    , currentThread : Maybe ForumThread, replies : List Reply
    , servers : List Server, convs : List Conversation
    , friends : List Friend, notifs : List Notification
    , searchUsers : List User, searchThreads : List ForumThread
    , currentServer : Maybe ServerData, currentProfile : Maybe User
    , invitePreview : Maybe InvitePreview
    , msg : List Message, nextBefore : Maybe Int
    , active : ActiveRoute, serverCache : Dict Int ServerData
    , drafts : Drafts, wsConnected : Bool, isLeader : Bool
    , tabId : String, subs : Set String
    , voice : VoiceState, callUI : CallUI, callMode : CallMode
    , soundEnabled : Bool, replyTo : Maybe ReplyPreview
    , toast : Maybe String, modal : Maybe String
    , settingsTab : String, inputText : String
    , sidebarOpen : Bool, ctxMenu : Maybe ContextMenu
    , threadReply : String, searchQuery : String
    , authMode : String, authUsername : String
    , authDisplayName : String, authPassword : String
    , serverName : String, serverDescription : String
    , booting : Bool
    }

type alias InvitePreview =
    { code : String, serverId : Int, channelId : Maybe Int, valid : Bool
    , serverName : String, serverDescription : String, serverIconUrl : String
    , memberCount : Int
    }

type alias ContextMenu =
    { items : List CtxItem, x : Int, y : Int }

type alias CtxItem =
    { label : String, icon : Maybe String, danger : Bool, sep : Bool
    , msg : Msg
    }


-- MSG

type Msg
    = NoOp
    | BootComplete
    | SetRoute String
    | AuthMode String
    | AuthUsername String
    | AuthDisplayName String
    | AuthPassword String
    | DoAuth
    | ApiSuccess String E.Value
    | ApiError String String
    | WsEvent E.Value
    | BridgeEvent String E.Value
    | Subscribe String
    | UnsubscribeAll
    | SendWs E.Value
    | Go String
    | ToggleSidebar
    | CloseSidebar
    | OpenDM Int
    | ShowUserPopup Int
    | CloseModal
    | Toast String
    | DismissToast
    | SetReplyTo Message
    | CancelReply
    | InputText String
    | SendMessage
    | DeleteMessage Int
    | LeaveConversation Int
    | MarkConvRead Int
    | CopyText String
    | JoinInvite
    | NewDmModal
    | SearchUsersModal
    | InviteModal Int
    | ChannelModal Int
    | EditServerModal Server
    | EditConversationModal Conversation
    | NewThreadModal (Maybe Int)
    | CreateThread Int String String
    | CreateServer String String
    | CreateChannel Int String String
    | UpdateProfile String Status String String String
    | ServerName String
    | ServerDescription String
    | ToggleSound
    | Logout
    | CloseCtx
    | CtxAction Int
    | LoadMoreMessages
    | SilentSync Bool
    | Tick Int
    | FileUpload String (Maybe String)
    | ReadFile String
    | SetSettingsTab String
    | ClearNotifs
    | SearchQuery String
    | DoSearch
    | UpdateDraft String String
    | AddPeopleModal Int
    | JoinCall Int
    | StartCall Int
    | AcceptCall Int
    | DeclineCall Int
    | EndCall
    | CallSignal Int String


-- DECODERS

decodeUser : D.Decoder User
decodeUser = D.succeed User
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

decodeConversation : D.Decoder Conversation
decodeConversation = D.succeed Conversation
    |> andMap (D.field "id" D.int)
    |> andMap (D.field "name" D.string |> defaultValue "")
    |> andMap (D.field "avatar_url" D.string |> defaultValue "")
    |> andMap (D.field "owner_id" D.int)
    |> andMap (D.field "created_at" D.int)
    |> andMap (D.field "updated_at" D.int)
    |> andMap (D.field "last_read_message_id" D.int |> defaultValue 0)
    |> andMap (D.field "muted" D.bool |> defaultValue False)
    |> andMap (D.field "member_count" D.int |> defaultValue 1)
    |> andMap (D.field "last_body" (D.nullable D.string))
    |> andMap (D.field "last_message_id" (D.nullable D.int))
    |> andMap (D.field "unread" D.int |> defaultValue 0)
    |> andMap (D.field "members" (D.list decodeMemberUser) |> defaultValue [])

decodeMemberUser : D.Decoder MemberUser
decodeMemberUser = D.map4 MemberUser
    (D.field "user" decodeUser) (D.field "role" D.string |> defaultValue "member")
    (D.field "muted" D.bool |> defaultValue False)
    (D.field "joined_at" D.int |> defaultValue 0)

decodeMessage : D.Decoder Message
decodeMessage = D.succeed Message
    |> andMap (D.field "id" D.int)
    |> andMap (D.field "scope" D.string)
    |> andMap (D.field "scope_id" D.int)
    |> andMap (D.field "user_id" D.int)
    |> andMap (D.field "username" D.string)
    |> andMap (D.field "display_name" D.string)
    |> andMap (D.field "avatar_url" D.string |> defaultValue "")
    |> andMap (D.field "body" D.string)
    |> andMap (D.field "reply_to_id" (D.nullable D.int))
    |> andMap (D.field "reply_to" (D.nullable decodeReplyPreview))
    |> andMap (D.field "created_at" D.int)
    |> andMap (D.field "edited_at" (D.nullable D.int))
    |> andMap (D.field "deleted_at" (D.nullable D.int))

decodeReplyPreview : D.Decoder ReplyPreview
decodeReplyPreview = D.map4 ReplyPreview
    (D.field "id" D.int) (D.field "user_id" D.int)
    (D.field "display_name" D.string) (D.field "body" D.string)

decodeForum : D.Decoder Forum
decodeForum = D.map8 Forum
    (D.field "id" D.int) (D.field "slug" D.string)
    (D.field "name" D.string) (D.field "description" D.string)
    (D.field "position" D.int) (D.field "thread_count" D.int |> defaultValue 0)
    (D.field "reply_count" D.int |> defaultValue 0)
    (D.field "last_at" (D.nullable D.int))

decodeThread : D.Decoder ForumThread
decodeThread = D.succeed ForumThread
    |> andMap (D.field "id" D.int)
    |> andMap (D.field "forum_id" D.int)
    |> andMap (D.field "forum_name" D.string |> defaultValue "")
    |> andMap (D.field "user_id" D.int)
    |> andMap (D.field "username" D.string)
    |> andMap (D.field "display_name" D.string)
    |> andMap (D.field "title" D.string)
    |> andMap (D.field "body" D.string |> defaultValue "")
    |> andMap (D.field "created_at" D.int)
    |> andMap (D.field "updated_at" D.int)
    |> andMap (D.field "reply_count" D.int |> defaultValue 0)
    |> andMap (D.field "views" D.int |> defaultValue 0)
    |> andMap (D.field "locked" D.bool |> defaultValue False)
    |> andMap (D.field "pinned" D.bool |> defaultValue False)

decodeReply : D.Decoder Reply
decodeReply = D.succeed Reply
    |> andMap (D.field "id" D.int)
    |> andMap (D.field "thread_id" D.int)
    |> andMap (D.field "user_id" D.int)
    |> andMap (D.field "username" D.string)
    |> andMap (D.field "display_name" D.string)
    |> andMap (D.field "avatar_url" D.string |> defaultValue "")
    |> andMap (D.field "body" D.string)
    |> andMap (D.field "created_at" D.int)
    |> andMap (D.field "updated_at" D.int)

decodeServer : D.Decoder Server
decodeServer = D.map8 Server
    (D.field "id" D.int) (D.field "name" D.string)
    (D.field "description" D.string |> defaultValue "")
    (D.field "icon_url" D.string |> defaultValue "")
    (D.field "owner_id" D.int) (D.field "role" D.string |> defaultValue "member")
    (D.field "member_count" D.int |> defaultValue 1)
    (D.field "created_at" D.int)

decodeChannel : D.Decoder Channel
decodeChannel = D.map7 Channel
    (D.field "id" D.int) (D.field "server_id" D.int)
    (D.field "name" D.string) (D.field "kind" D.string)
    (D.field "position" D.int) (D.field "topic" D.string |> defaultValue "")
    (D.field "created_at" D.int)

decodeServerMember : D.Decoder ServerMember
decodeServerMember = D.map4 ServerMember
    (D.field "user" decodeUser) (D.field "role" D.string)
    (D.field "muted" D.bool |> defaultValue False)
    (D.field "joined_at" D.int |> defaultValue 0)

decodeFriend : D.Decoder Friend
decodeFriend = D.map4 Friend
    (D.field "user" decodeUser) (D.field "status" D.string |> defaultValue "accepted")
    (D.field "incoming" D.bool |> defaultValue False)
    (D.field "outgoing" D.bool |> defaultValue False)

decodeNotification : D.Decoder Notification
decodeNotification = D.map6 Notification
    (D.field "id" D.int) (D.field "kind" D.string)
    (D.field "body" D.string) (D.field "url" D.string |> defaultValue "#")
    (D.field "seen" D.bool) (D.field "created_at" D.int)

decodeSyncData : D.Decoder { notifications : List Notification, conversations : List Conversation, servers : List Server, friends : List Friend, now : Int }
decodeSyncData = D.map5 (\notifications conversations servers friends now ->
    { notifications = notifications, conversations = conversations, servers = servers, friends = friends, now = now }
    )
    (D.field "notifications" (D.list decodeNotification) |> defaultValue [])
    (D.field "conversations" (D.list decodeConversation) |> defaultValue [])
    (D.field "servers" (D.list decodeServer) |> defaultValue [])
    (D.field "friends" (D.list decodeFriend) |> defaultValue [])
    (D.field "now" D.int)

type alias SyncData r = { r | notifications : List Notification, conversations : List Conversation, servers : List Server, friends : List Friend, now : Int }

defaultMsg : Message
defaultMsg = Message 0 "" 0 0 "" "" "" "" Nothing Nothing 0 Nothing Nothing


-- HELPERS

encodeMessage : { body : String, replyToId : Maybe Int } -> E.Value
encodeMessage m =
    E.object (List.filterMap identity
        [ Just ("body", E.string m.body)
        , Maybe.map (\rid -> ("reply_to_id", E.int rid)) m.replyToId
        ])

statusDecoder : D.Decoder Status
statusDecoder = D.string |> D.andThen (\s ->
    case s of
        "online" -> D.succeed Online
        "away" -> D.succeed Away
        "busy" -> D.succeed Busy
        "invisible" -> D.succeed Invisible
        _ -> D.succeed Offline
    )

encodeStatus : Status -> String
encodeStatus s = case s of
    Online -> "online"
    Away -> "away"
    Busy -> "busy"
    Invisible -> "invisible"
    Offline -> ""

statusToString : Status -> String
statusToString s = case s of
    Online -> "online"
    Away -> "away"
    Busy -> "busy"
    Invisible -> "invisible"
    Offline -> "offline"
