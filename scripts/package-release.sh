#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"

VERSION=$(tr -d '[:space:]' < VERSION)
[[ ${VERSION} == 1.6.0 ]] || { printf 'Unexpected VERSION: %s\n' "${VERSION}" >&2; exit 1; }

./scripts/release-check.sh

RELEASE_ROOT="${ROOT}/_build/default/rel/plainwire_relay"
DIST="${ROOT}/dist"
ARCH=$(uname -m)
ARCHIVE="${DIST}/plainwire-relay-${VERSION}-${ARCH}.tar.gz"
SOURCE_ARCHIVE="${DIST}/plainwire-${VERSION}-source.tar.gz"

mkdir -p "${DIST}"
rm -f "${ARCHIVE}" "${ARCHIVE}.sha256" "${SOURCE_ARCHIVE}" "${SOURCE_ARCHIVE}.sha256"

tar -C "${RELEASE_ROOT}" -czf "${ARCHIVE}" .
sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"

# The source package includes the generated frontend from the successful build,
# but excludes local databases, dependencies, compiler output, uploads, and secrets.
tar -C "${ROOT}" -czf "${SOURCE_ARCHIVE}" \
  --exclude='./_build' \
  --exclude='./node_modules' \
  --exclude='./dist' \
  --exclude='./data' \
  --exclude='./test-results' \
  --exclude='./tooling' \
  --exclude='./priv/static/elm/elm-stuff' \
  --exclude='./.git' \
  --exclude='./.env' \
  .
sha256sum "${SOURCE_ARCHIVE}" > "${SOURCE_ARCHIVE}.sha256"

printf 'Release package: %s\n' "${ARCHIVE}"
printf 'Source package:  %s\n' "${SOURCE_ARCHIVE}"
printf 'Checksums written beside each archive.\n'
