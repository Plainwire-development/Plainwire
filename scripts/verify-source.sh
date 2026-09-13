#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"
node --check priv/static/bootstrap.js
node --check priv/static/elm-bridge.js
for script in scripts/*.sh; do bash -n "${script}"; done
python3 - <<'PY'
from pathlib import Path
import json
version = Path('VERSION').read_text().strip()
assert version == '1.6.0'
assert f'{{vsn, "{version}"}}' in Path('src/plainwire_relay.app.src').read_text()
assert f'{{release, {{plainwire_relay, "{version}"}}' in Path('rebar.config').read_text()
assert f'attribute "data-ui-version" "{version}"' in Path('priv/static/elm/src/Main.elm').read_text()
json.loads(Path('package.json').read_text())
json.loads(Path('priv/static/elm/elm.json').read_text())
print('Source manifests, release versions, JavaScript and shell syntax passed.')
PY
printf 'Run npm run build for frontend compilation, npm run test:browser for browser regressions, and rebar3 eunit for backend tests.\n'
