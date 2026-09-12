# Plainwire 1.2.0

This release expands Plainwire from the 1.1 hardening pass into a more complete public-instance foundation.

## Frontend

- Reworked sign-in and registration into a responsive two-panel product entry screen.
- Added stronger registration validation and a password-strength indicator.
- Expanded User Settings with Chat and Privacy & Safety sections.
- Added configurable Enter-to-send behavior with Ctrl/Cmd+Enter mode.
- Added device-local link preview, animated media, compact spacing, and media preloading controls.
- Added polished account dialogs for password changes and active session review.
- Improved settings hierarchy, action cards, responsive behavior, focus states, and small-screen layout.
- Preserved the flatter visual language and avoided glowing call-to-action styling.

## Backend

- Added runtime registration policy through `PLAINWIRE_REGISTRATION_ENABLED`.
- Added runtime instance description configuration.
- Added authenticated active-session listing.
- Added logout-other-sessions support.
- Added password rotation that verifies the old password and revokes all other sessions.
- Added session IDs and indexes for account-management queries and session cleanup.
- Increased new-account password minimum to 10 characters.

## Existing 1.1 hardening retained

The WebRTC recovery, media-track handling, upload compression, upload ACL work, safe link embedding, configuration-driven limits, presence fixes, resizable screen sharing, and frontend preference work from the 1.1 hardening pass remain included.
