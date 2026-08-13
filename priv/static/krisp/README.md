# optional Krisp browser bits

Krisp AI needs Krisp's licensed browser SDK. Copy the complete Portal `dist`
bundle here. At minimum, these files need to exist:

```text
priv/static/krisp/krispsdk.mjs
priv/static/krisp/models/model_8.kef
priv/static/krisp/models/model_nc_mq.kef
```

Keep the other workers, worklets, WASM, and support files in their original
places too. Then set `PLAINWIRE_KRISP_ENABLED=true` and restart.

The proprietary files are gitignored on purpose. Without them, native browser
noise suppression keeps working. no SDK, no drama.
