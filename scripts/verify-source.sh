#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"
node --check priv/static/bootstrap.js
node --check priv/static/elm-bridge.js
node --check priv/static/call-health.js
node --check priv/admin/admin.js
node --check web/markdown.js
node --check web/interface.js
node --check web/source-hub.js
node --check scripts/build-rich-text.mjs
npm run test:rtc-contract
npm run test:ui-contract
npm run test:admin-contract
npm run test:integrations-contract
npm run test:storage-contract
npm run test:storage-tools
npm run test:v21-contract
npm run test:v21-app-contract
npm run test:v22-bot-contract
npm run test:v24-bot-contract
npm run test:scalability-contract
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
expected_versioned_assets = [
    '/assets/plainwire-mark.svg?v=__PLAINWIRE_VERSION__',
    '/assets/app.css?v=__PLAINWIRE_VERSION__',
    '/assets/bootstrap.js?v=__PLAINWIRE_VERSION__',
]
for asset in expected_versioned_assets:
    assert index_haml.count(asset) == 1, f'missing or duplicated versioned asset: {asset}'
assert index_haml.count('__PLAINWIRE_VERSION__') == len(expected_versioned_assets), 'unexpected version token outside the approved asset URLs'
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
for path in [*Path('scripts').rglob('*.py'), *Path('test').rglob('*.py')]:
    if '__pycache__' not in path.parts:
        ast.parse(path.read_text(), filename=str(path))
for path in [*Path('src').glob('*.erl'), *Path('sdk/erlang/src').glob('*.erl'), *Path('sdk/erlang/examples').glob('*.erl'), *Path('tools/load').glob('*.erl')]:
    body = path.read_text()
    # Source-only Erlang sanity pass for environments without erlc. This is not
    # a compiler replacement, but it catches broken delimiter edits while ignoring
    # strings, quoted atoms, comments, and single-character literals.
    stack = []
    mode = None
    escaped = False
    line = 1
    i = 0
    pairs = {')': '(', ']': '[', '}': '{'}
    while i < len(body):
        ch = body[i]
        if ch == '\n':
            line += 1
        if mode is not None:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif (mode == 'string' and ch == '"') or (mode == 'atom' and ch == "'"):
                mode = None
            i += 1
            continue
        if ch == '%':
            next_line = body.find('\n', i)
            i = len(body) if next_line < 0 else next_line
            continue
        if ch == '$' and i + 1 < len(body):
            i += 2
            continue
        if ch == '"':
            mode = 'string'
            i += 1
            continue
        if ch == "'":
            mode = 'atom'
            i += 1
            continue
        if ch in '([{':
            stack.append((ch, line))
        elif ch in ')]}':
            assert stack and stack[-1][0] == pairs[ch], f'unmatched Erlang delimiter in {path}:{line}: {ch}'
            stack.pop()
        i += 1
    assert mode is None and not stack, f'unclosed Erlang delimiter/string in {path}: {stack[-5:]}'
    # Catch accidental duplicated standalone result expressions such as two
    # consecutive `{error, forbidden}` terms inside one case arm. Erlang's real
    # compiler remains the authority; this protects source-only verification too.
    duplicate_result = re.search(r'(?m)^\s*(\{(?:error|ok),\s*[^\n]+\})\s*\n\s*\1\s*$', body)
    assert not duplicate_result, f'duplicated Erlang result expression in {path}: {duplicate_result.group(1)}'
    # Exact duplicate top-level clauses are unreachable warning noise at best
    # and usually a copy/paste regression. Catch them even when they are not
    # adjacent (the real Erlang compiler remains authoritative).
    lines = body.splitlines()
    function_heads = {}
    for idx, line_text in enumerate(lines, 1):
        # Erlang top-level function clauses begin in column 1 in this codebase.
        # Do not mistake indented anonymous-fun callbacks such as
        # `with_json(Req, fun(M, Req1) ->` for function declarations.
        if line_text != line_text.lstrip():
            continue
        stripped = line_text.rstrip()
        if re.fullmatch(r'[a-z][A-Za-z0-9_@]*\(.*\)(?: when .*)? ->(?:.*[;.]?)?', stripped):
            function_heads.setdefault(stripped, []).append(idx)
    duplicated_heads = {head: at for head, at in function_heads.items() if len(at) > 1}
    assert not duplicated_heads, f'exact duplicate Erlang function clause(s) in {path}: {duplicated_heads}'
    # named ETS initialization is a runtime crash if the same table is created
    # twice by one init path. This caught a realtime-registry regression that a
    # delimiter-only source check cannot see.
    named_ets = re.findall(r'ets:new\((\?[A-Z][A-Z0-9_]*)\s*,\s*\[named_table', body)
    duplicates = sorted({name for name in named_ets if named_ets.count(name) > 1})
    assert not duplicates, f'duplicate named ETS initialization in {path}: {duplicates}'
authored_sources = [
    *Path('src').glob('*.erl'), *Path('sdk/erlang/src').glob('*.erl'), *Path('sdk/erlang/examples').glob('*.erl'),
    *Path('priv/static/elm/src').rglob('*.elm'),
    Path('priv/static/elm-bridge.js'), Path('priv/static/bootstrap.js'), Path('priv/static/call-health.js'),
    *Path('priv/admin').glob('*'),
    *Path('native').rglob('*.c'), *Path('native').rglob('*.f90'), *Path('web').glob('*.js'),
    *Path('tools/load').glob('*.erl'), *Path('tools/load/gleam/src').glob('*.gleam'),
    Path('tools/load/live_load.py'),
]
unfinished = re.compile(r'(?i)\b(?:TODO|FIXME|XXX|unimplemented|stubbed|placeholder implementation|not implemented)\b')
for source in authored_sources:
    hit = unfinished.search(source.read_text())
    assert not hit, f'unfinished marker in authored source {source}: {hit.group(0)}'
db_source = Path('src/pw_db.erl').read_text()
# Guard known Erlang single-assignment regressions that were caught by erlc in
# the 1.8.0 admin paths. These checks are intentionally exact enough to avoid
# pretending to be a compiler while still preventing the same unsafe bindings
# from re-entering a source-only release.
assert '{ok, [ExistingRoleValue]} -> ExistingRoleValue' in db_source
assert 'EffectiveRole = case ExistingRole of undefined -> RequestedRole; _ -> ExistingRole end' in db_source
assert '{ok, [Uid, _EnrollmentRole, Username' in db_source
assert 'LimitI -> LimitI end' in db_source
assert 'BeforeI -> max(1, BeforeI) end' in db_source
assert not re.search(r'\{ok, \[Role\]\} -> Role[\s\S]{0,260}Role = case ExistingRole', db_source), 'unsafe Erlang Role binding regression in admin enrollment'
assert not re.search(r'case pw_util:int\(Limit0\)[\s\S]{0,120}; I -> I end[\s\S]{0,180}case pw_util:int\(BeforeId0\)[\s\S]{0,120}; I ->', db_source), 'unsafe reused Erlang I binding regression in admin audit pagination'
migration_ids = [int(v) for v in re.findall(r'(?m)^\s*\{(\d+), \[', db_source)]
assert migration_ids == list(range(1, max(migration_ids) + 1)), f'non-contiguous or duplicate DB migrations: {migration_ids}'
# Scalability hardening must remain operator-visible and source-verifiable.
env_example = Path('.env.example').read_text()
for knob in [
    'PLAINWIRE_DB_CALL_TIMEOUT_MS', 'PLAINWIRE_REDIS_POOL_SIZE',
    'PLAINWIRE_REDIS_ASYNC_QUEUE', 'PLAINWIRE_REDIS_SYNC_QUEUE',
    'PLAINWIRE_ASYNC_WORKERS', 'PLAINWIRE_ASYNC_MAX_QUEUE',
    'PLAINWIRE_CLUSTER_OUTBOX_LIMIT', 'PLAINWIRE_CLUSTER_EVENT_MAX_AGE_MS',
    'PLAINWIRE_CLUSTER_DRAIN_BATCH', 'PLAINWIRE_CLUSTER_DEDUP_LIMIT',
    'PLAINWIRE_HTTP_CONNECTION_SUPERVISORS', 'PLAINWIRE_HTTP_SEND_TIMEOUT_MS',
    'PLAINWIRE_ADMIN_SEND_TIMEOUT_MS', 'PLAINWIRE_WS_MAX_CONNECTIONS',
    'PLAINWIRE_WS_UPGRADES_PER_IP_MIN', 'PLAINWIRE_WS_UPGRADES_GLOBAL_MIN',
    'PLAINWIRE_PRESENCE_WATCH_MAX'
]:
    assert knob in env_example, f'missing scalability setting from .env.example: {knob}'
# Every backend environment switch must be discoverable by operators. Hidden
# knobs make scaling and security behavior impossible to reason about during an incident.
env_refs = set()
for erlang_source in Path('src').glob('*.erl'):
    env_refs.update(re.findall(r'PLAINWIRE_[A-Z0-9_]+', erlang_source.read_text()))
missing_env_docs = sorted(name for name in env_refs if name not in env_example)
assert not missing_env_docs, f'backend environment names missing from .env.example: {missing_env_docs}'
assert Path('docs/SCALING.md').is_file(), 'missing docs/SCALING.md'
assert not list(Path('.').rglob('__pycache__')), 'Python bytecode cache must not be present in the release tree'
assert not list(Path('.').rglob('*.pyc')), 'Python bytecode must not be present in the release tree'
registry_source = Path('src/pw_realtime_registry.erl').read_text()
assert registry_source.count('ets:new(?RTC_PID_TAB,') == 1, 'RTC PID table must be initialized exactly once'
assert 'PLAINWIRE_PRESENCE_WATCH_MAX' in registry_source, 'presence watch limit must be enforced at the registry boundary'
cluster_source = Path('src/pw_cluster.erl').read_text()
assert 'handle_info(drain, S = #{ready := false})' in cluster_source, 'cluster outbox must survive a transient transport outage'
assert 'erlang:send_after(1000, self(), drain)' in cluster_source
assert 'prune_expired_outbox(ets:lookup_element(?OUTBOX, drain_batch, 2))' in cluster_source, 'expired cluster events must be pruned even while transport is unavailable'
wire_source = Path('src/pw_cluster_wire.erl').read_text()
assert 'valid_id_list(List, Max) -> valid_id_list(List, Max, 0)' in wire_source and 'valid_id_list(_, _, _) -> false' in wire_source, 'cluster wire ID lists must be bounded and improper-list safe'
assert 'safe_list(T, D, 0, 2048)' in wire_source and 'safe_list(_, _, _, _) -> false' in wire_source, 'generic cluster list validation must be bounded and improper-list safe'
partisan_source = Path('src/pw_cluster_partisan.erl').read_text()
assert 'Reliable = Channel =:= events' in partisan_source
assert 'ack => Reliable' in partisan_source and 'retransmission => Reliable' in partisan_source
assert '{send_timeout_close, true}' in Path('src/pw_sup.erl').read_text()
assert 'process_flag(trap_exit, true)' in db_source, 'DB lane crashes must be isolated from the pool owner'
assert "ets:insert(?POOL_CONNS, {Idx, unavailable})" in db_source
assert "self() ! {restart_lane, Idx}" in db_source
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
