# Client themes and plugins

Plainwire 2.0 supports local themes and plugins from the client extension manager. Extensions are stored in the browser profile for that Plainwire installation; enabling a client extension does not write executable code to the server database.

## Themes

Themes are Less source. Plainwire compiles them in the client and applies the generated CSS to the whole app. Less JavaScript execution is disabled and remote `@import` is rejected so a theme cannot quietly turn into a script loader.

Use existing Plainwire CSS variables and theme hooks where possible. A good theme should change appearance without depending on generated Elm class names.

## Plugins

Plugins run in dedicated Web Workers rather than directly in the page. The worker response has a separate Content Security Policy that denies network connections, script imports and nested workers. Removing JavaScript globals alone cannot enforce that policy, since plugin code can restore them from browser prototypes. Only the worker permits JavaScript evaluation; the page retains its existing script policy. Plainwire exposes a smaller bridge for supported actions such as notifications, namespaced local storage, composer insertion and authenticated same-origin API requests. API writes require an explicit grant in the extension manager.

This isolation is a safety boundary and a stability boundary: a plugin exception should not take down the Elm application or the active call UI.

Enabled plugins start after authentication and stop on logout. Periodic account reconciliation keeps the existing workers running so their state and startup actions are preserved. A theme compiler failure does not prevent plugins from starting.

Extensions are still user-installed code. Only install code you trust, and disable an extension first when diagnosing client-specific behavior.
