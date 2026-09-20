# Plainwire 2.1.1

A focused interface and call-quality update.

## Interface

- Settings fill their available pane, with the sidebar and scrollbar aligned to its edges. Developer forms reflow to avoid clipped controls and text.
- Narrow desktop windows and phones get layouts based on the available content width, including the source browser and home page.
- Both tours have clearer progress, more readable cards, larger controls and bounded scrolling. The source tour adds keyboard navigation, shorter explanations, responsive positioning and focus restoration.
- Call notifications and controls, server pickers, workspace menus and dialogs use more consistent spacing and surfaces.
- The composer’s copy/paste context menu now has an opaque background.

## Call history

Completed direct and group calls appear in the chat with their duration and a Call again action. The server starts timing when a second participant joins and records the event when the room empties. Reconnects and device changes preserve the session; unanswered calls keep their existing missed-call behavior. History uses the existing encrypted message storage and realtime delivery path. Migration 50 adds the completed-call message kind.

As with missed-call records, persistence uses the bounded asynchronous job queue. Abrupt server termination can lose an unfinished call summary; it does not reconstruct call history after a restart.

## Native connection analysis

- Larger pairwise trend windows use bounded heap sorting. A local benchmark of 10,000 full windows was about 20% faster, with identical numerical outputs for that benchmark; performance varies by host.
- Missing intervals no longer count as observed evidence, and stale measurements cannot report a healthy live connection.
- A recovery advisory distinguishes healthy recent conditions from a poor historical score.
- The native request deadline now also covers incomplete frame headers, while idle workers remain untimed.

These changes analyze connection statistics; they do not process or enhance audio samples. Native analysis remains optional, and calls continue if it is unavailable.

## Validation

The release is checked with `make check NATIVE=1`, including browser, WebRTC, native numerical/protocol and Erlang EUnit tests. Responsive settings coverage exercises seven window widths from 320 to 1920 pixels.
