#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"

fail() { printf 'verify-source: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok  %s\n' "$*"; }

printf 'Plainwire source verification\n'

node --check priv/static/bootstrap.js >/dev/null
node --check priv/static/elm-bridge.js >/dev/null
pass 'browser JavaScript syntax'

for script in scripts/*.sh; do
  bash -n "${script}"
done
pass 'shell syntax'

python3 - <<'PY'
from pathlib import Path
import json
json.loads(Path('package.json').read_text())
json.loads(Path('priv/static/elm/elm.json').read_text())
PY
pass 'JSON manifests'

grep -Fq '{vsn, "1.5.0"}' src/plainwire_relay.app.src || fail 'application version is not 1.5.0'
grep -Fq '{release, {plainwire_relay, "1.5.0"}' rebar.config || fail 'release version is not 1.5.0'
grep -Fq 'PLAINWIRE_DEFAULT_THEME=system' .env.example || fail 'system theme is not the deployment default'
grep -Fq 'attribute "data-ui-version" "1.5.0"' priv/static/elm/src/Main.elm || fail 'Elm UI fingerprint is missing'
grep -Fq 'Plainwire 1.5.0 visual refinement and call workspace' priv/static/style.scss || fail '1.5 UI fingerprint is missing'
grep -Fq 'data-call-drag-handle' priv/static/elm/src/Main.elm || fail 'call drag handles are missing'
grep -Fq 'plainwire_call_window_v2' priv/static/elm-bridge.js || fail 'persistent call window state is missing'
grep -Fq 'pw-float-title-wrap' priv/static/elm-bridge.js || fail 'screen share window chrome is missing'
pass 'release fingerprints'

python3 - <<'PY'
from pathlib import Path

scss = Path('priv/static/style.scss').read_text()
if scss.count('{') != scss.count('}'):
    raise SystemExit('unbalanced SCSS braces')
if scss.count('(') != scss.count(')'):
    raise SystemExit('unbalanced SCSS parentheses')

# Lightweight Elm delimiter scan. Ignore comments and string/char literals so
# punctuation inside copy does not create false positives. This is not a
# substitute for elm make, but it catches accidental truncation cleanly.
elm = Path('priv/static/elm/src/Main.elm').read_text()
stack = []
i = 0
line = 1
state = 'code'
block_depth = 0
pairs = {')': '(', ']': '[', '}': '{'}
while i < len(elm):
    c = elm[i]
    n = elm[i + 1] if i + 1 < len(elm) else ''
    if c == '\n':
        line += 1
    if state == 'code':
        if c == '-' and n == '-':
            state = 'line'; i += 2; continue
        if c == '{' and n == '-':
            state = 'block'; block_depth = 1; i += 2; continue
        if elm.startswith('"""', i):
            state = 'triple'; i += 3; continue
        if c == '"':
            state = 'string'; i += 1; continue
        if c == "'":
            state = 'char'; i += 1; continue
        if c in '([{':
            stack.append((c, line))
        elif c in ')]}':
            if not stack or stack[-1][0] != pairs[c]:
                raise SystemExit(f'Elm delimiter mismatch at line {line}')
            stack.pop()
        i += 1; continue
    if state == 'line':
        if c == '\n': state = 'code'
        i += 1; continue
    if state == 'block':
        if c == '{' and n == '-': block_depth += 1; i += 2; continue
        if c == '-' and n == '}':
            block_depth -= 1; i += 2
            if block_depth == 0: state = 'code'
            continue
        i += 1; continue
    if state == 'string':
        if c == '\\': i += 2; continue
        if c == '"': state = 'code'
        i += 1; continue
    if state == 'triple':
        if elm.startswith('"""', i): state = 'code'; i += 3; continue
        i += 1; continue
    if state == 'char':
        if c == '\\': i += 2; continue
        if c == "'": state = 'code'
        i += 1; continue
if stack or state not in ('code', 'line'):
    raise SystemExit('Elm source ended with an unclosed delimiter, literal, or comment')

# Do the same basic truncation check for Erlang. Character literals need special
# handling because forms such as $] are data rather than a closing delimiter.
def scan_erlang(path):
    source = path.read_text()
    stack = []
    state = 'code'
    line = 1
    i = 0
    pairs = {')': '(', ']': '[', '}': '{'}
    while i < len(source):
        c = source[i]
        if c == '\n': line += 1
        if state == 'code':
            if c == '%': state = 'comment'; i += 1; continue
            if c == '"': state = 'string'; i += 1; continue
            if c == "'": state = 'atom'; i += 1; continue
            if c == '$':
                i += 3 if i + 1 < len(source) and source[i + 1] == '\\' else 2
                continue
            if c in '([{': stack.append((c, line))
            elif c in ')]}':
                if not stack or stack[-1][0] != pairs[c]:
                    raise SystemExit(f'Erlang delimiter mismatch in {path} at line {line}')
                stack.pop()
            i += 1; continue
        if state == 'comment':
            if c == '\n': state = 'code'
            i += 1; continue
        if state in ('string', 'atom'):
            if c == '\\': i += 2; continue
            if (state == 'string' and c == '"') or (state == 'atom' and c == "'"):
                state = 'code'
            i += 1; continue
    if stack or state not in ('code', 'comment'):
        raise SystemExit(f'Erlang source ended unexpectedly in {path}')

for erl_path in list(Path('src').glob('*.erl')) + list(Path('test').glob('*.erl')):
    scan_erlang(erl_path)

# Keep release copy suitable for normal repositories and public documentation.
for path in list(Path('src').glob('*.erl')) + list(Path('priv/static').rglob('*')) + list(Path('scripts').glob('*.sh')) + [Path('README.md'), Path('RELEASE_NOTES_1.5.0.md')]:
    if path.is_file():
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        if '\u2014' in text:
            raise SystemExit(f'em dash found in {path}')
PY
pass 'source structure and typography checks'

if command -v sass >/dev/null 2>&1; then
  tmp_css=$(mktemp)
  trap 'rm -f "${tmp_css:-}"' EXIT
  sass priv/static/style.scss "${tmp_css}" --no-source-map >/dev/null
  grep -Fq 'Plainwire 1.5.0 visual refinement and call workspace' "${tmp_css}" || fail 'compiled CSS fingerprint missing'
  pass 'SCSS compiler'
else
  printf '  skip Sass compiler not installed\n'
fi

if command -v elm >/dev/null 2>&1; then
  tmp_js=$(mktemp)
  trap 'rm -f "${tmp_css:-}" "${tmp_js:-}"' EXIT
  (cd priv/static/elm && elm make src/Main.elm --output="${tmp_js}" --optimize >/dev/null)
  grep -Fq 'data-ui-version' "${tmp_js}" || fail 'compiled Elm fingerprint missing'
  pass 'Elm compiler'
else
  printf '  skip Elm compiler not installed\n'
fi

if command -v rebar3 >/dev/null 2>&1 && command -v erl >/dev/null 2>&1; then
  rebar3 compile >/dev/null
  rebar3 eunit >/dev/null
  pass 'Erlang compile and EUnit'
else
  printf '  skip Erlang/rebar3 not installed\n'
fi

printf 'Source verification completed.\n'
