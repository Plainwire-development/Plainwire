# Interface refresh, version 1.7.2

This archive keeps version **1.7.2**, as requested. Its app shell carries `data-ui-revision="interface-2"` so it can be distinguished from the earlier 1.7.2 build. The backend's existing asset fingerprint changes with the generated frontend. If your deployment pins `PLAINWIRE_ASSET_VERSION`, update that override when deploying this refresh.

## What changed

The workspace now has a quieter navigation column, a bounded main surface, readable light/dark controls, consistent spacing and typography, and a more compact home overview. Unread conversations keep a badge and stronger name instead of another large coloured card. Chat text has a bounded reading width; code, quotations, composer and message actions share the same spacing rules. Existing themes, accent colours, density and font-size preferences remain available.

- **Jump to… / Ctrl+K / Command+K:** search your loaded conversations, servers, current server's text channels and core pages locally. Arrow keys choose a result, Enter opens it, and Escape closes the dialog even after typing. This is separate from the existing global content search; it makes no search API requests.
- **Navigation width:** drag the sidebar's right edge or focus its resize control and use Left/Right. Home or double-click resets it. The browser saves the width; phones retain their drawer layout.
- **Workspace menu:** Create server and Join with invite are grouped behind one menu. It closes on action, Escape or outside interaction.
- **Jump to latest:** appears when reading older messages. New messages preserve reading position. Choosing the button returns to live conversation. Old message DOM is retained and only added media/embed subtrees are inspected.
- **Settings:** fixed section navigation, one content scroller, a shorter two-column profile form on desktop, associated field labels, clearer controls and larger mobile fields. Switching sections resets the content scroll position. Existing settings functionality is retained.
- **Call health:** visible quality scores and a labelled recent-jitter chart show the collected evidence. The panel distinguishes connection analysis from live browser measurements and an unavailable analysis service. Closed diagnostics do not rebuild hidden DOM, and identical snapshots are not rendered twice.

## Fortran and the worker

The existing nineteen-number protocol is unchanged. Fortran now weights rate means and dispersion by their measured intervals. A short polling interval cannot outweigh a longer one merely because each produced one row. Gaps longer than twenty seconds contribute no observed duration, and supported metrics must provide at least ten observed seconds before qualifying for a score. Evidence reporting discounts gaps. Unsupported jitter no longer distorts an otherwise supported loss-stability estimate.

The C worker handles interrupted/partial reads and writes explicitly. Its one-second request alarm also covers incomplete frame input and output, preventing a caller that holds a partial frame open from stranding the worker. Idle workers remain blocking, without polling or an idle timer. Queue limits, the BEAM timeout, failure isolation and optional adaptive screen limits are retained.

Build the native executable on the deployment host with `make native` or `make build NATIVE=1`. It is intentionally excluded from the portable archive. The worker is optional; ordinary calls continue without it. See [Call health](CALL_HEALTH.md).

## Verification

Browser tests exercise keyboard quick switching, menu dismissal, sidebar resizing, settings scrolling, live-message reading position, returning to the latest message, retaining old message nodes and avoiding full-document media scans. They also retain the Markdown, formatting, long-composer, sending, invite, theme and mobile checks.

`PLAINWIRE_TEST_NATIVE=1 npm run test:rtc` takes samples from real browser RTCPeerConnections, passes those samples to the actual C/Fortran binary through a test transport, and verifies its returned score appears in call details. It also verifies that collapsed call diagnostics receive zero DOM mutations across a sampling interval. The test transport supplies a simple recommendation label; real Erlang decoding and recommendation policy are exercised separately by EUnit. Audio, screen viewing, switching, microphone replacement and call cleanup regressions are retained.

Native tests cover interval weighting, suspension gaps, unsupported-metric isolation, an incomplete frame held open, prior numerical fixtures, malformed frames, deterministic random windows and sequential requests. All 84 EUnit tests pass with the actual native worker enabled.

These are local browser and native checks, not a live deployment or hardware interoperability certification. See [Build status](../BUILD_STATUS.md) for remaining deployment checks.

## Design reference

[Linear's redesign account](https://linear.app/now/how-we-redesigned-the-linear-ui) informed the focus on aligned navigation, surface hierarchy and reduced visual noise. Plainwire's implementation uses its existing components and icon assets; no external design assets or new font downloads were added.
