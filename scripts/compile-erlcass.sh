#!/bin/bash
# OTP 29 runs `erl -s init stop` before `-eval`, so erlcass never writes
# c_src/env.mk and rebar3 stops before Plainwire's beams exist. The expression
# already ends in halt(), and that form works on OTP 27 and 28 as well.
# A missing native toolchain must not block the PostgreSQL build.
set -u
if [[ ! -f Makefile && ! -f c_src/nif.mk ]]; then
  echo "erlcass: sources missing; native driver skipped" >&2
  exit 0
fi

patch_eval() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -q -- '-s init stop' "$file" || return 0
  local tmp
  tmp="$(mktemp)"
  sed 's/-s init stop //g' "$file" > "$tmp"
  mv "$tmp" "$file"
}

patch_eval Makefile
patch_eval c_src/nif.mk

if ! make nif_compile; then
  echo "erlcass: native driver was not built; Scylla stays unavailable and PostgreSQL is unchanged" >&2
fi
exit 0
