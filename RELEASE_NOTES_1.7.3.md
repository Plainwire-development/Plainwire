# Plainwire 1.7.3

Plainwire 1.7.3 fixes call state restoration and makes screen sharing more useful without changing the existing interface style.

## Calls and screen sharing

* Deafen now mutes playback and the microphone without losing the user's earlier mute choice. Undeafening restores the correct state, and leaving a deafened call no longer contaminates the next call.
* Voice-room participants use the profile data carried by the live roster, preventing temporary `User (id)` labels after a hard refresh.
* Screen sharing can include audio from sources that expose it. Captured audio and microphone audio share the existing negotiated sender, including during source changes and rollback.
* Remote screen viewers can collapse to a compact title bar while their stream and audio continue, or stop watching explicitly.

## Interface and reliability

* Settings have clearer navigation, section descriptions, saved-state guidance, choice controls, character counts, and screen-share preferences.
* Message scrolling now honors an initial jump-to-latest request even when the message element mounts later.
* Special message cards keep their intended size on narrow layouts, and syntax highlighting starts reliably inside nested scrollers.
* Backend voice state normalizes impossible combinations such as deafened without muted or shared audio without an active screen.

The stylesheet updates intentionally use each source language's native features: SCSS mixins, includes, and nested parent selectors for the screen viewer; Less parameterized mixins, selector interpolation, variables, guarded responsive mixins, and nesting for settings.
