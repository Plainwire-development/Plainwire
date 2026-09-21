# Plainwire 2.4.1

2.4.1 is a stability patch: the new-account tour, live calls, and a hosted-only forgot-password path.

## Tour

Skip and continue no longer depend on `window.confirm`, which some browsers silently block. Action buttons appear immediately. Typing is capped and cannot iterate a string character-by-character. A full-screen mask stops clicks from leaking through the spotlight into the app underneath. If a tour target is missing, the guide stays on screen instead of deadlocking.

## Calls

The collapsed call bar is draggable. Its previous drag handle was a `<button>`, so pointer drag was ignored. Call window position is stored on `html` CSS variables so Elm re-renders cannot snap the bar back. Live call timers run in a custom element so the top “In call” bar no longer flickers every tick. Remote audio retries on user gestures and when the tab becomes visible, which is the usual “refresh to hear them” failure.

## Password reset

Accounts can add an optional email and verify it. Password reset is sent only to a verified address. No email means no reset. SMTP credentials are environment-only. Mail is enabled automatically on `plainwi.re` when SMTP is configured, and stays off on self-hosted instances unless `PLAINWIRE_MAIL_ENABLED=true`.
