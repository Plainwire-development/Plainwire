# Screen sharing

Join a call or voice room, then choose **Share**. A browser chooser controls which screen, window or tab is captured. Remote participants choose **Watch screen**. Screen capture requires HTTPS or a browser-trusted local development origin and explicit permission.

In call details, expand **Screen sharing** to choose a saved quality preference:

| Preset | Requested capture ceiling | Two-person video bitrate ceiling | Intended use |
| --- | --- | --- | --- |
| Balanced | 1600 × 900, 30 fps | 2.5 Mb/s per peer | Everyday sharing |
| Text & detail | 1920 × 1080, 30 fps | 3.5 Mb/s per peer | Documents and code |
| Smooth motion | 1920 × 1080, 60 fps | 4.5 Mb/s per peer | Moving content |

These are upper bounds, not promised output. The browser, source size, codec and available network decide actual quality. The existing mesh call architecture sends a stream to each peer; configured participant-count tiers reduce each sender's bitrate, frame rate and resolution. Call-health congestion limits can reduce these further. Small private calls remain the intended deployment.

**Change shared screen** opens a new chooser while the current capture continues. Cancelling keeps the existing share. Replacement failures attempt to restore the previous track; only successful replacement releases the old capture. Stopping sharing or leaving also invalidates an in-flight chooser or replacement. Screen audio is not captured by this release; the microphone continues on its separate audio sender.

The remote viewer opens alongside call details on desktop. Drag its header or resize its lower-right corner; use the window button to center and fit it. **Fill view** crops to fill the window; **Fit view** preserves the complete image. Fullscreen retains the viewer controls. Picture in picture is shown only when supported by the browser. On phones the window button expands/collapses the viewer. Close the remote viewer to stop watching; choose Watch screen again to reopen it. Closing **Your screen** stops your broadcast.

## HDR: what is and is not detected

There is no standardized HDR-on capture constraint in the browser screen-capture API. Plainwire cannot guarantee a 10-bit codec, HDR capture, end-to-end HDR transmission, or the operating system's final display output. It preserves the native capture → WebRTC → video element path without adding a canvas conversion or an application SDR filter. Where supported, CSS permits the video element's native dynamic range.

An HDR-capable display is detected separately using the `dynamic-range: high` media query. This does **not** prove that the selected source or received video is HDR. The viewer inspects a decoded `VideoFrame` on media load, playback and resolution changes, releases that frame immediately, and labels only `pq` or `hlg` transfer metadata as HDR. Recognized SDR metadata is labelled SDR; inaccessible or unrecognized metadata is labelled Colour not reported. This avoids a continuous pixel-processing loop. Browsers can tone-map captured HDR content to SDR before transmission, in which case the viewer must not call it HDR.

The automated suite exercises metadata reporting with a PQ fixture and actual SDR video, as well as fullscreen, mobile expansion, both RTP video directions, source changes, cancellation, sender failure and stopping mid-change. Physical HDR displays and real HDR sources were not available for validation. Firefox, Safari, mobile capture and cross-browser HDR interoperability require testing on your target devices.

Primary specifications: [Screen Capture](https://www.w3.org/TR/screen-capture/), [WebCodecs and video colour metadata](https://www.w3.org/TR/webcodecs/), and [CSS HDR colour](https://www.w3.org/TR/css-color-hdr-1/).
