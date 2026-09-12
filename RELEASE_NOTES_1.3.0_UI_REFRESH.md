# Plainwire 1.3.0 UI Refresh

This pass focuses on making the frontend feel more deliberate, more modern, and less visually noisy.

## Main goals

- Reduce the "prototype" feel in the shell layout
- Remove some of the awkward spacing and overlapping visual weight between panels
- Make the sidebar, top bar, settings, chat surfaces, and cards feel more coherent
- Tone down flashy styling and replace it with cleaner surfaces and stronger spacing
- Improve consistency across home, forum, server, DM, settings, and modal views

## Frontend changes

### Shell and navigation
- Added a clearer desktop application shell with spaced panels, rounded panel boundaries, and stronger visual hierarchy
- Refined the server rail with cleaner button treatment and less awkward hover behavior
- Improved the left sidebar and right member pane styling to look more like intentional product panels instead of flat blocks
- Cleaned up the top bar so it sits more naturally inside the main surface
- Updated navigation wording to be more polished

### Cards and content surfaces
- Reworked cards, stat blocks, server create panels, forum cards, settings cards, and invite cards with more cohesive radii, shadows, and borders
- Added more consistent spacing and panel rhythm throughout the app
- Better centered main page sections with a larger, more product-like content width

### Chat and messaging
- Refined message spacing, hover states, composer styling, embeds, and chat header surfaces
- Improved the visual separation between header, message list, and composer without making the screen noisy
- Reduced some of the harsher message hover effects and made the interface feel more stable

### Settings
- Reworked the settings layout so it feels more like a proper settings experience with stronger section separation
- Improved the settings sidebar, top header, action cards, and form controls
- Smoothed out the visual style of switches, controls, and settings panels

### Mobile handling
- Preserved the cleaner desktop treatment while collapsing gracefully back to edge-to-edge on smaller screens
- Prevented the desktop panel framing from making mobile layouts feel cramped

## Bug fixes and cleanup
- Added missing CSS custom property fallbacks for `--bg1`, `--panel`, and `--border`
- Smoothed out a number of places where older layered styling passes were fighting each other visually

## Files touched
- `priv/static/style.scss`
- `priv/static/elm/src/Main.elm`

## Notes
- This is a visual refresh pass focused on frontend quality, clarity, and cohesion
- The biggest changes are in styling, layout polish, and navigation presentation
