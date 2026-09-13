#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
FC=${FC:-gfortran}
CC=${CC:-cc}
command -v "$FC" >/dev/null || { printf 'Install gfortran to build the optional call-health worker.\n' >&2; exit 127; }
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
mkdir -p priv/bin
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -fstack-protector-strong -c native/media_quality/worker.c -o "$BUILD/worker.o"
"$FC" -std=f2008 -O2 -Wall -Wextra -Werror -fcheck=bounds -J "$BUILD" -c native/media_quality/quality.f90 -o "$BUILD/quality.o"
"$FC" "$BUILD/worker.o" "$BUILD/quality.o" -o "$BUILD/pw-media-quality"
install -m 755 "$BUILD/pw-media-quality" priv/bin/pw-media-quality
printf 'Built priv/bin/pw-media-quality for this host.\n'
