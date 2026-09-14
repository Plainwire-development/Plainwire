#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"
node --check priv/static/bootstrap.js
node --check priv/static/elm-bridge.js
node --check priv/static/call-health.js
node --check web/markdown.js
node --check web/interface.js
node --check scripts/build-rich-text.mjs
for script in scripts/*.sh; do bash -n "${script}"; done
python3 - <<'PY'
from pathlib import Path
import json
import ast
version = Path('VERSION').read_text().strip()
assert version == '1.7.2-3'
assert f'{{vsn, "{version}"}}' in Path('src/plainwire_relay.app.src').read_text()
assert f'{{release, {{plainwire_relay, "{version}"}}' in Path('rebar.config').read_text()
assert f'attribute "data-ui-version" "{version}"' in Path('priv/static/elm/src/Main.elm').read_text()
assert f'_ -> <<"{version}">>' in Path('src/pw_client_config.erl').read_text()
assert f'?assertEqual(<<"{version}">>, maps:get(version, Config))' in Path('test/pw_client_config_tests.erl').read_text()
for path in [*Path('scripts').glob('*.py'), *Path('test').glob('*.py')]:
    ast.parse(path.read_text(), filename=str(path))
json.loads(Path('package.json').read_text())
json.loads(Path('priv/static/elm/elm.json').read_text())
print('Source manifests, release versions, JavaScript and shell syntax passed.')
PY
printf 'Run npm run build for frontend compilation, npm run test:browser and npm run test:rtc for browser regressions, and rebar3 eunit for backend tests.\n'
