# Plainwire 2.1.2

A focused link-preview and server-customization update.

## Link previews

- Link previews use richer, compact cards with clearer source, content-type, favicon and media presentation while retaining Plainwire's own visual language.
- Messages can show up to five distinct previews, with duplicate links collapsed and responsive layouts for narrow chat panes and phones.
- Preview extraction now handles more useful document types, including PDF, plain-text and JSON responses, and recognizes additional Open Graph metadata.
- Unsafe or unsupported targets continue to use the existing server-side URL validation and bounded fetch path.

## Server invites

- Plainwire Wire invite URLs render as dedicated server cards instead of generic links.
- Both the current `plainwi.re` URL and compatible invite URL forms are recognized.
- Invite cards show the server identity, description, membership and channel context, plus expiry or revocation state when applicable.
- The missing-invite-card regression is covered in the browser suite and the invite lookup endpoint is covered by backend tests.

## Server customization

- Server customization is organized into clearer identity, appearance and discovery sections without expanding the settings footprint unnecessarily.
- Logo, accent, banner, description, community mode and invite defaults have improved explanations, previews and status feedback.
- The customization pane and preview reflow across desktop, narrow-window and mobile widths.

## Validation

The release is checked with `make check`, including source contracts, responsive browser coverage, bidirectional WebRTC tests and 146 Erlang EUnit tests.
