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
npm run test:rtc-contract
npm run test:ui-contract
npm run test:release-contract
for script in scripts/*.sh; do bash -n "${script}"; done
python3 - <<'PY'
from pathlib import Path
import json
import ast
import re
version = Path('VERSION').read_text().strip()
assert re.fullmatch(r'\d+\.\d+\.\d+(?:-\d+)?', version)
assert f'{{vsn, "{version}"}}' in Path('src/plainwire_relay.app.src').read_text()
assert f'{{release, {{plainwire_relay, "{version}"}}' in Path('rebar.config').read_text()
assert f'attribute "data-ui-version" "{version}"' in Path('priv/static/elm/src/Main.elm').read_text()
assert f'_ -> <<"{version}">>' in Path('src/pw_client_config.erl').read_text()
assert f'?assertEqual(<<"{version}">>, maps:get(version, Config))' in Path('test/pw_client_config_tests.erl').read_text()
assert Path(f'RELEASE_NOTES_{version}.md').is_file()
readme = Path('README.md').read_text()
assert f'Current release: **{version}**' in readme
assert f'[{version} release notes](RELEASE_NOTES_{version}.md)' in readme
index_haml = Path('priv/static/index.haml').read_text()
assert index_haml.count('__PLAINWIRE_VERSION__') == 2
build_haml = Path('scripts/build-haml.sh').read_text()
assert "readFileSync('VERSION'" in build_haml and "replaceAll('__PLAINWIRE_VERSION__', version)" in build_haml
build_css = Path('scripts/build-css.mjs').read_text()
assert "readFile(resolve(root, 'VERSION')" in build_css and 'Plainwire ${version} workspace' in build_css
bootstrap = Path('priv/static/bootstrap.js').read_text()
assert "searchParams.get('v')" in bootstrap and 'version: bootVersion' in bootstrap and 'asset_version: bootVersion' in bootstrap
for deploy_script in ['scripts/update-openrc-release.sh', 'scripts/install-openrc-release.sh']:
    body = Path(deploy_script).read_text()
    assert 'VERSION=$(<"${REPO}/VERSION")' in body
    assert 'CSS_FINGERPRINT="Plainwire ${VERSION} workspace"' in body
for path in [*Path('scripts').glob('*.py'), *Path('test').glob('*.py')]:
    ast.parse(path.read_text(), filename=str(path))
for path in Path('src').glob('*.erl'):
    body = path.read_text()
    # Catch accidental duplicated standalone result expressions such as two
    # consecutive `{error, forbidden}` terms inside one case arm. Erlang's real
    # compiler remains the authority; this protects source-only verification too.
    duplicate_result = re.search(r'(?m)^\s*(\{(?:error|ok),\s*[^\n]+\})\s*\n\s*\1\s*$', body)
    assert not duplicate_result, f'duplicated Erlang result expression in {path}: {duplicate_result.group(1)}'
    # A merge artifact that repeats a top-level function head on adjacent lines
    # is always invalid Erlang and is easy to miss in source-only environments.
    lines = body.splitlines()
    for idx, (left, right) in enumerate(zip(lines, lines[1:]), 1):
        if left == right and re.fullmatch(r'[a-z][A-Za-z0-9_@]*\(.*\)(?: when .*)? ->', left):
            raise AssertionError(f'duplicated Erlang function head in {path}:{idx}: {left}')
authored_sources = [
    *Path('src').glob('*.erl'),
    *Path('priv/static/elm/src').rglob('*.elm'),
    Path('priv/static/elm-bridge.js'), Path('priv/static/bootstrap.js'), Path('priv/static/call-health.js'),
    *Path('native').rglob('*.c'), *Path('native').rglob('*.f90'), *Path('web').glob('*.js'),
]
unfinished = re.compile(r'(?i)\b(?:TODO|FIXME|XXX|unimplemented|stubbed|placeholder implementation|not implemented)\b')
for source in authored_sources:
    hit = unfinished.search(source.read_text())
    assert not hit, f'unfinished marker in authored source {source}: {hit.group(0)}'
db_source = Path('src/pw_db.erl').read_text()
migration_ids = [int(v) for v in re.findall(r'(?m)^\s*\{(\d+), \[', db_source)]
assert migration_ids == list(range(1, max(migration_ids) + 1)), f'non-contiguous or duplicate DB migrations: {migration_ids}'
package = json.loads(Path('package.json').read_text())
lock = json.loads(Path('package-lock.json').read_text())
elm_manifest = json.loads(Path('priv/static/elm/elm.json').read_text())
assert package['devDependencies']['elm'] == '0.19.1-6'
assert lock['packages']['']['devDependencies']['elm'] == '0.19.1-6'
assert package.get('engines', {}).get('node') == '>=20.19'
assert lock['packages'][''].get('engines', {}).get('node') == '>=20.19'
assert package['allowScripts'] == {
    '@parcel/watcher@2.5.6': True,
    'elm@0.19.1-6': True,
    'esbuild@0.28.2': True,
}
assert lock['packages']['node_modules/less']['version'] == '4.9.1'
assert 'node_modules/image-size' not in lock['packages']
assert lock['packages']['node_modules/probe-image-size']['version'] == '7.4.0'
print('Source manifests, release versions, JavaScript and shell syntax passed.')
PY
printf 'Run npm run build for frontend compilation, npm run test:browser and npm run test:rtc for browser regressions, and rebar3 eunit for backend tests.\n'
