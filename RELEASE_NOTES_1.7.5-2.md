# Plainwire 1.7.5-2

This stabilization release improves call recovery, server administration, and
message interaction behavior.

## Highlights

- Added bounded WebRTC peer-session rebuilding when remote audio stalls or
  ends, while preserving active transports across mute and deafen changes.
- Added transaction-safe server deletion with exact-name confirmation,
  cleanup of related message and upload records, and live access revocation.
- Added message reactions with normalized storage, access checks, batched
  aggregation, viewer state, and rate limiting.
- Added server-member profiles and privilege-aware role-color presentation.
- Added touch long-press context menus and responsive styling for the new
  reaction, profile, and server-deletion interfaces.

## Reliability and compatibility

- Channel posting, forwarding, moving, and server deletion now use a
  consistent database lock order to avoid deletion races.
- Deleted messages no longer retain hidden reaction records.
- RTC recovery is scoped to the current room roster and capped to prevent
  reconnect storms.
- Browser contract coverage was expanded for RTC recovery, server deletion,
  reactions, profiles, mobile interactions, and release-version wiring.
