# Plainwire 2.3.0

Plainwire 2.3.0 is a focused voice-message reliability and usability release.

## Voice messages

- Replaces browser-native voice-note controls with a responsive Plainwire player that matches the rest of the chat interface.
- Keeps the recorded duration and progress position stable immediately, including Chromium recordings whose WebM metadata does not initially contain a finite duration.
- Discovers missing WebM duration metadata in the background, so a recording no longer needs to play all the way through before seeking behaves normally.
- Adds scrubbing, mute, download, buffering feedback and 1×, 1.5× and 2× playback speeds.
- Adds an in-dialog recording preview so a voice note can be reviewed before it is uploaded and attached.

## Reliability

- Stops microphone capture and revokes local preview resources when the recorder is closed through Cancel, the close button or the backdrop.
- Makes the five-minute recording cutoff idempotent and prevents duplicate recorder-stop attempts.
- Keeps an in-flight voice-note upload associated with the conversation where recording began instead of inserting it into a newly opened conversation.
- Includes browser and source-contract coverage for the custom player, stable duration fallback and responsive layout.

## Compatibility and upgrade

- No database migration or new runtime dependency is required.
- The Bot API and its 2.2.0 SDK packages are unchanged and remain compatible with this release.
- The release is validated by `make check`, including browser, responsive UI, WebRTC and backend suites.
