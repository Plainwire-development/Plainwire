# Group call invitations

Join a group call, then right-click an absent member in the People list and choose **Ring to call**. On touch screens, press and hold the member row. A group follows the existing conversation definition: more than two members.

The recipient sees the caller and group name. Accepting joins the current call; declining or ignoring it leaves everyone else connected. Microphone capture starts only after acceptance. Pending ringing appears beside the member in the sender's People list, with the repeat action disabled.

Only accepted group members with active human accounts can ring or be rung. Blocks involving either participant and another group member deny ringing, consistent with group call access. The sender must own the connected call seat in the current socket. The recipient must be online and available. Invitations do not queue for offline users. Room capacity is checked when ringing and again when accepting.

Only one targeted invitation can be pending per recipient. A caller can ring the same recipient once per 30 seconds; the recipient can receive three new targeted invitations per minute across callers. The deadline uses `PLAINWIRE_CALL_RING_MS` (45 seconds by default, clamped to 10–120 seconds). The existing `PLAINWIRE_VOICE_MAX_PARTICIPANTS` limit also applies.

Leaving the call, switching rooms or handing the caller's seat to another tab cancels its outstanding invitations. Disconnecting the caller or the recipient's last socket, revoking group access, declining and timeout remove the matching invitation. Accepting in one recipient tab dismisses it in all other tabs without capturing their microphones. Reconnecting another recipient tab can display a still-valid pending invitation.

## WebSocket protocol

Send `call_invite` with `conversation_id` and `to_user_id` from the socket that owns the call seat. Success returns `call_invite_status` with `conversation_id`, `to_user_id`, `invite_id`, `expires_at` (Unix milliseconds), and `status: "ringing"`. Repeating the same pending request returns the same token and deadline. Failure returns `call_invite_error` with the conversation, target and error, without leaving or replacing the existing call.

The recipient receives the normal `call_incoming` event with `conversation_id`, `from_user_id`, a public caller `profile`, plus `invite_id` and `expires_at`. Accept or decline with `call_accept` or `call_decline`, the matching `conversation_id` and `invite_id`. The token is bound to the authenticated recipient and live call; possession alone does not grant membership. Acceptance rechecks both accounts, membership and blocks before consuming the token, so permission changes while ringing still apply.

Completion sends the recipient `call_invite_ended` with the conversation, token and reason, and updates the sender through `call_invite_status`. Clients dismiss or update only the matching token. Acceptance sends `call_accepted` only to the accepting socket, followed by the normal call roster and peer signaling. Invitation completion never emits call-wide cancellation or termination events.

Initial group calling, ordinary direct calls, joining an existing call, voice channels, and screen sharing retain their existing protocols. Existing clients can join a live group call using the normal join action; update both the server and frontend to use targeted invitation controls.
