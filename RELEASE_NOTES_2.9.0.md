# Plainwire 2.9.0

## Chat, calls and profile fixes

- Name new unnamed group DMs `group dm 1`, `group dm 2`, and so on using a counter for their creator. Keep custom group names and ordinary direct chats; do not reuse new group numbers after departure/deletion.
- Let users listen to calls and share their screen when a microphone is missing or permission is denied. Add **Enable microphone** to retry during the same call. Preserve mute/deafen across asynchronous microphone replacement and permission completion.
- Keep fresh group timestamps correct when a device clock is fast. Return fresh server time from cached sessions and label fresh messages **Just now**.
- Clear stale server controls during navigation, refresh the server list immediately after creation, and preserve channel creation forms on errors. Make **Add channel**/**Add category** easier to find on existing servers and reject unsupported channel kinds.
- Display profile editing banners as centered, non-repeating cover images. Wrap long names within the preview on small screens.
- Preserve JSON null values so exported uncategorized channels can be imported again. Avoid optional Scylla driver shutdown errors in PostgreSQL deployments.

## Server folders and template imports

- Drag servers onto each other to make folders; expand/collapse folders and keep unread badges. Store folders with the account and detect conflicting saves from other devices.
- Add a keyboard and mobile organizer for moving servers, naming folders, and ungrouping them. Show all server entries in the scrollable rail and group them in the mobile server sheet.
- Preview Blank, Friends, Gaming, Study group and Community server presets before creation.
- Import public Discord template links/codes or saved template JSON, and export Plainwire server structure from Server settings. Validate imports and create their channels, categories and role labels atomically.
- Omit restricted/unsupported Discord channels and managed roles. Custom imports start with member access and imported role permissions disabled for owner review; Discord channel permission overrides are not transferred. Messages, members, credentials and integrations are not migrated.
- Restrict Discord fetching to its fixed official API with verified TLS, public address pinning, no redirects, response limits and rate limits. Keep preview text safe and prevent stale selections from replacing newer previews.

Migrations 58 and 59 add the group counter and account server layouts. Upgrade frontend and backend together. Existing E2EE text/history and bot/server features remain supported. See [folders and templates](docs/SERVER_TEMPLATES.md), the [review record](docs/SECURITY_AUDIT_2.9.0.md), and the existing [E2EE threat model](docs/END_TO_END_ENCRYPTION.md).

## Validation and artifacts

The full package check passed with 298 backend tests and the complete browser, security, encryption and WebRTC suites. A 250-user realtime smoke and the live-load harness passed; the locked npm dependency audit reported zero advisories. The extracted runtime passed real PostgreSQL, authorization, template round-trip and encrypted DM checks with the build toolchain unavailable. Source and Linux x86_64 OTP runtime archives include SHA-256 checksums. The runtime omits the optional native call-health worker and Scylla native driver; those features require their documented native builds.
