# Plainwire 2.6.1

2.6.1 improves browser call recovery and screen sharing. It carries no database
migration and no new environment variables. Installs on 2.6.0 can upgrade
directly.

## Calls and reconnects

- Recover pending call starts, joins, and answers after signaling reconnects,
  while discarding signals queued for a previous connection.
- Prevent overlapping room updates from leaving a call stuck until a page
  refresh.
- Recover microphone capture when a device disconnects or a processed audio
  track ends. Retry capture with a bounded delay, fall back to the default
  microphone when needed, and resume after device or connectivity changes.
- Repair peer connections when changing screen or microphone tracks fails, so
  screen video and available system audio can resume without reloading.

## Mobile and regression coverage

Call controls recover through mobile foreground and connectivity changes.
Browser regressions now exercise real two-participant media, signaling loss,
microphone disconnects, screen audio, and rollback paths.

Screen audio availability still depends on the browser, operating system, and
the source selected in the share picker.
